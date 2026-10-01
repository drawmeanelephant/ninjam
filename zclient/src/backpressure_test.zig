//! #14: full Session.run reproduction, not a finalizeInterval seam test.
//! A peer stops reading for four seconds while still sending pings. A Unix
//! stream socket pins SO_SNDBUF exactly (Darwin loopback TCP silently absorbs
//! much more). The peer then drains and decodes on the SAME connection.
const std = @import("std");
const builtin = @import("builtin");
const session = @import("session.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const instrument = @import("instrument.zig");
const clock = @import("clock.zig");
const SampleSource = struct {
    samples: []const f32,
    fn fill(ctx: *anyopaque, offset: u64, dst: []f32) void {
        const self: *SampleSource = @ptrCast(@alignCast(ctx));
        for (dst, 0..) |*sample, i| {
            const index = offset + i;
            sample.* = if (index < self.samples.len) self.samples[@intCast(index)] else 0;
        }
    }
};
const vorbis = @import("vorbis.zig");

const blackhole_ms = 4000;
const duration_ms = 7200;
const bar_ms = 800;

const Progress = struct {
    started: std.atomic.Value(u64) = .init(0),
    times: [64]i128 = undefined,
    io: std.Io,

    fn select(ctx: *anyopaque, _: u64) bool {
        const self: *Progress = @ptrCast(@alignCast(ctx));
        const n = self.started.load(.monotonic);
        if (n < self.times.len) self.times[@intCast(n)] = clock.nowNs(self.io);
        self.started.store(n + 1, .release);
        return true;
    }
};

const Peer = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    fd: std.posix.socket_t,
    progress: *Progress,
    at_two_s: u64 = 0,
    at_four_s: u64 = 0,
    finals: u64 = 0,
    recovered: u64 = 0,
    recovered_seq: ?u64 = null,
    bad_frame: bool = false,
    decode_failed: bool = false,

    fn run(self: *Peer) void {
        defer _ = std.posix.system.close(self.fd);
        self.play() catch |e| {
            std.debug.print("backpressure peer failed: {s}\n", .{@errorName(e)});
            self.bad_frame = true;
        };
    }

    fn play(self: *Peer) !void {
        var flags: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(self.fd, std.c.F.GETFL, @as(c_int, 0)))));
        flags.NONBLOCK = true;
        _ = std.c.fcntl(self.fd, std.c.F.SETFL, @as(c_int, @bitCast(flags)));
        if (builtin.os.tag == .macos) {
            try std.posix.setsockopt(self.fd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, &std.mem.toBytes(@as(c_int, 1)));
        }
        try std.posix.setsockopt(self.fd, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, 4096)));
        var challenge: [16]u8 = undefined;
        @memcpy(challenge[0..8], "\x01\x23\x45\x67\x89\xab\xcd\xef");
        std.mem.writeInt(u32, challenge[8..12], 0x100, .little); // 1 s keepalive
        std.mem.writeInt(u32, challenge[12..16], proto.PROTO_VER_CUR, .little);
        try self.send(proto.MSG_AUTH_CHALLENGE, &challenge);
        try self.awaitType(proto.MSG_AUTH_USER);
        try self.send(proto.MSG_AUTH_REPLY, "\x01kujamba\x00\x01");
        try self.awaitType(proto.MSG_SET_CHANNEL_INFO);
        var config: [4]u8 = undefined;
        std.mem.writeInt(u16, config[0..2], 300, .little);
        std.mem.writeInt(u16, config[2..4], 4, .little);
        try self.send(proto.MSG_CONFIG_CHANGE_NOTIFY, &config);

        const t0 = clock.nowMs(self.io);
        var sampled = false;
        while (clock.nowMs(self.io) - t0 < blackhole_ms) {
            // Keep the receive-side stall detector out of the experiment.
            try self.send(proto.MSG_KEEPALIVE, "");
            if (!sampled and clock.nowMs(self.io) - t0 >= 2000) {
                self.at_two_s = self.progress.started.load(.acquire);
                sampled = true;
            }
            try sleep(self.io, 50);
        }
        self.at_four_s = self.progress.started.load(.acquire);

        var conn = net.Conn{ .io = self.io, .fd = self.fd };
        var payload = @import("buf.zig").Buf.init(self.alloc);
        defer payload.deinit();
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(self.alloc);
        var guid: [16]u8 = undefined;
        var begun = false;
        var last_ping = clock.nowMs(self.io);
        while (clock.nowMs(self.io) - t0 < duration_ms + 3000) {
            if (clock.nowMs(self.io) - last_ping >= 50) {
                try self.send(proto.MSG_KEEPALIVE, "");
                last_ping = clock.nowMs(self.io);
            }
            if (!try conn.pollReadable(5)) continue;
            const msg = conn.readMessage(&payload) catch |e| switch (e) {
                error.EndOfStream, error.ConnectionResetByPeer => return,
                error.WouldBlock => continue,
                else => return e,
            };
            if (msg.mtype == proto.MSG_UPLOAD_INTERVAL_BEGIN) {
                if (msg.payload.len != 25) return error.BadUploadBegin;
                @memcpy(&guid, msg.payload[0..16]);
                begun = true;
                encoded.clearRetainingCapacity();
            } else if (msg.mtype == proto.MSG_UPLOAD_INTERVAL_WRITE) {
                if (msg.payload.len < 17) return error.BadUploadWrite;
                if (!begun or !std.mem.eql(u8, &guid, msg.payload[0..16])) return error.UnexpectedGuid;
                const data = msg.payload[17..];
                if (encoded.items.len + data.len > 1 << 20) return error.UploadTooLarge;
                try encoded.appendSlice(self.alloc, data);
                if (msg.payload[16] & 1 != 0) {
                    self.finals += 1;
                    var decoded = vorbis.decodeMemory(self.alloc, encoded.items) catch {
                        self.decode_failed = true;
                        continue;
                    };
                    defer decoded.deinit();
                    if (decoded.frames() == 0 or decoded.rms() < 0.02) self.decode_failed = true;
                    for (self.at_four_s..64) |seq| {
                        var expected: [16]u8 = undefined;
                        instrument.deriveGuid(42, seq, 0, &expected);
                        if (std.mem.eql(u8, &expected, &guid)) {
                            self.recovered += 1;
                            if (self.recovered_seq == null) self.recovered_seq = seq;
                        }
                    }
                    begun = false;
                    encoded.clearRetainingCapacity();
                }
            }
        }
        return error.PeerDeadline;
    }

    fn send(self: *Peer, kind: u8, data: []const u8) !void {
        var frame: [128]u8 = undefined;
        frame[0] = kind;
        std.mem.writeInt(u32, frame[1..5], @intCast(data.len), .little);
        @memcpy(frame[5..][0..data.len], data);
        const bytes = frame[0 .. 5 + data.len];
        var off: usize = 0;
        const deadline = clock.nowMs(self.io) + 2000;
        while (off < bytes.len and clock.nowMs(self.io) < deadline) {
            const rc = if (builtin.os.tag == .macos)
                std.posix.system.write(self.fd, bytes[off..].ptr, bytes.len - off)
            else
                std.posix.system.send(self.fd, bytes[off..].ptr, bytes.len - off, std.posix.MSG.NOSIGNAL);
            switch (std.posix.errno(rc)) {
                .SUCCESS => off += @intCast(rc),
                .INTR => {},
                .AGAIN => try sleep(self.io, 1),
                else => return error.PeerWrite,
            }
        }
        if (off != bytes.len) return error.PeerWriteTimeout;
    }

    fn awaitType(self: *Peer, kind: u8) !void {
        // Handshake frames are small. Read exactly one at a time, so no
        // upload bytes are inadvertently drained before the blackout starts.
        var header: [5]u8 = undefined;
        try self.readExact(&header);
        const len = std.mem.readInt(u32, header[1..5], .little);
        if (header[0] != kind or len > 1024) return error.BadHandshake;
        var body: [1024]u8 = undefined;
        try self.readExact(body[0..len]);
    }

    fn readExact(self: *Peer, bytes: []u8) !void {
        var off: usize = 0;
        const deadline = clock.nowMs(self.io) + 2000;
        while (off < bytes.len and clock.nowMs(self.io) < deadline) {
            const n = std.posix.read(self.fd, bytes[off..]) catch |e| switch (e) {
                error.WouldBlock => {
                    try sleep(self.io, 1);
                    continue;
                },
                else => return e,
            };
            if (n == 0) return error.EndOfStream;
            off += n;
        }
        if (off != bytes.len) return error.HandshakeTimeout;
    }
};

fn sleep(io: std.Io, ms: u32) !void {
    const d: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake };
    try d.sleep(io);
}

pub fn reproduce(alloc: std.mem.Allocator, io: std.Io, check: bool) !void {
    var fds: [2]std.posix.socket_t = undefined;
    if (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds)) != .SUCCESS) return error.SocketPairFailed;
    var peer_owned = true;
    defer {
        if (peer_owned) _ = std.posix.system.close(fds[1]);
    }
    for (fds) |fd| {
        var flags: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)))));
        flags.NONBLOCK = true;
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(flags)));
    }
    var conn = net.Conn{ .io = io, .fd = fds[0], .last_recv_ms = clock.nowMs(io) };
    var owned = true;
    defer if (owned) conn.close();
    try std.posix.setsockopt(conn.fd, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 8192)));
    var actual: c_int = 0;
    var optlen: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(conn.fd, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, @ptrCast(&actual), &optlen) != 0) return error.GetSendBuf;
    var progress = Progress{ .io = io };
    var peer = Peer{ .io = io, .alloc = alloc, .fd = fds[1], .progress = &progress };
    var samples: [48000]f32 = undefined;
    var seed: u64 = 123;
    for (&samples) |*s| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        s.* = @as(f32, @floatFromInt(@as(i64, @intCast(seed % 2001)) - 1000)) / 1500;
    }
    var fill = SampleSource{ .samples = &samples };
    try std.Io.Dir.cwd().createDirPath(io, "zig-cache/backpressure");
    var s = try session.Session.init(alloc, io, .{
        .srate = 48000,
        .source = .{ .custom = .{ .ctx = &fill, .fill = SampleSource.fill } },
        .channel_names = &.{"custom-source"},
        .id_seed = 42,
        .plan = .{ .ctx = &progress, .selectFor = Progress.select },
        .duration_ms = duration_ms,
        .out_dir = "zig-cache/backpressure",
        .transcript_path = "zig-cache/backpressure/session.log",
    });
    defer s.deinit();
    s.conn = conn;
    owned = false;
    s.log.quiet = true;
    const thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});
    peer_owned = false;
    const t0 = clock.nowNs(io);
    const stats = s.run() catch s.stats;
    const elapsed_ms = @divTrunc(clock.nowNs(io) - t0, std.time.ns_per_ms);
    if (s.conn) |*c| c.close();
    s.conn = null;
    thread.join();
    const started = progress.started.load(.acquire);
    var max_gap: i128 = 0;
    for (1..@min(started, progress.times.len)) |i| {
        max_gap = @max(max_gap, progress.times[i] - progress.times[i - 1]);
    }
    std.debug.print(
        \\BACKPRESSURE sndbuf_requested=8192 sndbuf_actual={d} blackhole_ms={d} bar_ms={d}
        \\  elapsed_ms={d} started_at_2s={d} started_at_4s={d} bars_started={d} max_bar_gap_ms={d}
        \\  uploaded={d} dropped={d} backpressured={d} discarded_bytes={d} upload_stall_ms={d} ok={} err="{s}"
        \\  peer_finals={d} recovered_finals={d} first_recovered_seq={any} bad_frame={} decode_failed={}
        \\  transcript=zig-cache/backpressure/session.log
        \\
    , .{
        actual,                                     blackhole_ms,                           bar_ms,
        elapsed_ms,                                 peer.at_two_s,                          peer.at_four_s,
        started,                                    @divTrunc(max_gap, std.time.ns_per_ms), stats.intervals_uploaded,
        stats.intervals_dropped,                    stats.intervals_backpressured,          stats.upload_bytes_dropped,
        stats.upload_stall_ns / std.time.ns_per_ms, stats.ok,                               stats.failText(),
        peer.finals,                                peer.recovered,                         peer.recovered_seq,
        peer.bad_frame,                             peer.decode_failed,
    });
    if (check) {
        if (!stats.ok or stats.intervals_dropped == 0 or stats.upload_bytes_dropped == 0) return error.MissingDrops;
        if (stats.intervals_backpressured != stats.intervals_dropped) return error.WrongDropCount;
        if (peer.at_four_s <= peer.at_two_s or max_gap > 2 * bar_ms * std.time.ns_per_ms) return error.AudioClockStalled;
        if (peer.bad_frame or peer.decode_failed or peer.recovered == 0) return error.NoRecovery;
        if (elapsed_ms > duration_ms + 1500) return error.SessionDeadlineExceeded;
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());
    const measure_only = args.len == 2 and std.mem.eql(u8, args[1], "--measure-only");
    try reproduce(init.gpa, init.io, !measure_only);
}

test "#14: constrained stream uploads drop without stopping Session.run, then recover" {
    try reproduce(std.testing.allocator, std.testing.io, true);
}
