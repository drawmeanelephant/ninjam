//! M5 timing harness — the measurement rig for #13 (server-clock discipline)
//! and #14 (upload backpressure).
//!
//! Both issues live on the same line of code: `finalizeInterval` writes an
//! interval's upload inline, on the path that drives the audio clock, and the
//! interval grid is open-loop (`interval_start_ns += interval_ns`), so anything
//! that stalls the write stalls the music. Neither failure is reachable from a
//! unit test — they need a real socket and a real peer that misbehaves, which is
//! exactly what this file provides.
//!
//! `proto_fuzz.zig` already proves the general point that "a live-path stream
//! really goes live"; this rig is the other half. A fuzz stream is *hostile but
//! well-formed* — every message arrives on time. The failure modes here are the
//! ones fuzzing structurally cannot reach:
//!
//!  - **backpressure (#14)**: a peer that stops reading, so the socket's send
//!    buffer fills and `write` would block. The client must drop bars, not
//!    freeze. `blackholeServer` stops reading for a fixed window and then
//!    drains, which makes the stall finite and therefore *measurable* instead
//!    of a hung test.
//!  - **clock drift (#13)**: not a crash but a silent divergence between the
//!    local bar grid and the grid derived from the server's `0x02` arrival.
//!    Silence encodes to almost nothing, so a silent source would never notice
//!    a slow link; `toneSource` makes the uploads big enough to actually fill a
//!    buffer.
//!
//! These portable fixtures use synthetic PCM, not application synthesis or
//! phrase policy. The same regressions run in the conformance client and in
//! applications that vendor its session engine.
//!
//! `runClockedSession` is the shared driver: it stands up a loopback listener,
//! plays one scripted server, runs a real `Session` against it, and hands back
//! both the session's `Stats` and the server-side truth (how many bytes it
//! managed to read). Tests assert on the *difference*.

const std = @import("std");
const builtin = @import("builtin");
const session = @import("session.zig");
const proto = @import("proto.zig");
const net = @import("net.zig");
const instrument = @import("instrument.zig");
const SampleSource = struct {
    samples: []const f32,
    fn source(self: *SampleSource) session.Source {
        return .{ .custom = .{ .ctx = self, .fill = fill } };
    }
    fn fill(ctx: *anyopaque, offset: u64, dst: []f32) void {
        const self: *SampleSource = @ptrCast(@alignCast(ctx));
        for (dst, 0..) |*sample, i| {
            const index = offset + i;
            sample.* = if (index < self.samples.len) self.samples[@intCast(index)] else 0;
        }
    }
};
const clock = @import("clock.zig");
const vorbis = @import("vorbis.zig");

/// Relative on purpose: `Session.run` creates its out_dir via `Dir.cwd()`, and
/// `zig-cache/` is already gitignored.
const timing_out_dir = "zig-cache/session-timing-out";

/// The scripted server's side of a run, so a test can compare what the client
/// *thought* it sent against what actually crossed the socket.
pub const ServerView = struct {
    /// bytes the server managed to read out of the client before it stopped
    /// (its receive window), i.e. the uploads that were not dropped
    bytes_read: u64 = 0,
    /// true if the server saw the client's socket go away
    saw_eof: bool = false,
};

// ---- the scripted server ----------------------------------------------------

/// Same wrapping as `proto_fuzz.zig`'s `Listener`, for the same two macOS
/// reasons: `close` must be idempotent (several exit paths reach it) and the
/// accept has to be interruptible (macOS does not wake a thread blocked in
/// `accept` when the fd is closed, so the join would deadlock).
const Listener = struct {
    server: std.Io.net.Server,
    io: std.Io,
    closed: bool = false,
    stop: std.atomic.Value(bool) = .init(false),

    fn init(server: std.Io.net.Server, io: std.Io) Listener {
        const l = Listener{ .server = server, .io = io };
        // Non-blocking accept: EAGAIN surfaces as error.WouldBlock and the loop
        // can check `stop` between attempts. Note std.c.O is a packed struct,
        // and net.zig's own setNonblocking hardcodes Linux's 0o4000 — a silent
        // no-op on macOS — so set the named bit through the struct instead.
        const fd = server.socket.handle;
        var o: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)))));
        o.NONBLOCK = true;
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(o)));
        return l;
    }

    fn port(self: *const Listener) u16 {
        return self.server.socket.address.getPort();
    }

    fn close(self: *Listener) void {
        if (self.closed) return;
        self.closed = true;
        self.stop.store(true, .release);
        self.server.deinit(self.io);
    }
};

/// What the scripted server does once the session is live.
pub const ServerScript = struct {
    /// milliseconds to go completely silent — not one `read`, so the client's
    /// send buffer, the TCP window and the server's receive buffer all fill and
    /// `write` starts returning EAGAIN. This is the #14 hazard made finite.
    blackhole_ms: u32 = 0,
    /// cap on the whole server's life, so a session that never stops cannot hang
    /// the test.
    lifetime_ms: u32 = 4000,
    /// `SO_RCVBUF` to request on the listening socket (inherited by the
    /// accepted socket). Small on purpose, and the size is a *test* knob, not a
    /// fidelity compromise: a full socket takes exactly the same code path at
    /// 8 KiB as at 256 KiB, and the kernel clamps to its own minimum anyway.
    /// It matters because the client uploads at the reference client's bitrate
    /// (64 kbps mono, `quality = 0.0` — `Options.quality`'s default), which is
    /// only ~8 KB/s, so with stock loopback buffers a peer has to stop reading
    /// for *seconds* before `write` ever returns EAGAIN. That is itself worth
    /// knowing: backpressure here is a slow-peer failure, not a jitter failure.
    recv_buf_bytes: i32 = 4096,
};

const accept_deadline_waits: u32 = 2000; // ~2 s of 1 ms polls

/// `std.testing.io` is wired up by the test runner for normal runs. This file
/// is not a fuzz target, but it shares the harness shape, so it carries the
/// same guard for the same reason: a future `--fuzz` wiring should not have to
/// rediscover that the fuzz runner never touches `testing.io_instance`.
fn harnessIo() std.Io {
    if (builtin.fuzz) {
        if (timing_io == null) timing_io = .init(std.heap.page_allocator, .{});
        return timing_io.?.io();
    }
    return std.testing.io;
}

var timing_io: ?std.Io.Threaded = null;
/// Plays the server for one run: accept, handshake, config, then whatever the
/// script says, then drain.
///
/// Raw posix (net.zig's own style) rather than `Io.Threaded`: Threaded asserts
/// accept-EAGAIN is a zig bug ("errnoBug"), so a non-blocking listener must not
/// accept through the io vtable. Everything here is poll-gated instead, so the
/// stop flag and every deadline can interrupt it.
/// Read from the server's socket until a frame of type `want` arrives, counting
/// everything read into `view`. Returns false on EOF, error, or deadline.
///
/// This replaces a fixed `drain(cfd, view, 200)` at each handshake step. The
/// fixed budget was the harness's second-largest source of wall-clock
/// dependence: it slept the full 200 ms twice, so the handshake took 400 ms
/// before the client could go live, and the client — which polls for readability
/// every 20 ms and has its own auth timeout — sometimes ran out of session first.
/// That showed up as `msgs_recv=2` and `bars=0` on the macOS runner about half
/// the time, with no error and no hint, because the failure was a *missing*
/// `0x02` rather than a wrong one.
///
/// Waiting for the message the server is actually waiting for is both faster
/// (a loopback round trip, so ~1 ms instead of 400) and a real assertion: the
/// old code sent the config whether or not the client had registered its
/// channel, so a client that never sent `0x82` still got a config and still
/// looked healthy.
fn readUntilType(cfd: std.posix.socket_t, view: *ServerView, want: u8, deadline_ms: u32) bool {
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    var waited: u32 = 0;
    while (waited < deadline_ms) {
        const n = std.posix.read(cfd, buf[len..]) catch |e| switch (e) {
            error.WouldBlock => {
                _ = sleepMs(1);
                waited += 1;
                continue;
            },
            else => return false,
        };
        if (n == 0) return false;
        view.bytes_read += n;
        len += n;
        var off: usize = 0;
        while (len - off >= 5) {
            const t = buf[off];
            const l = std.mem.readInt(u32, buf[off + 1 ..][0..4], .little);
            if (l > net.max_payload or len - off < 5 + l) break;
            off += 5 + @as(usize, l);
            if (t == want) return true;
        }
        if (off > 0) {
            std.mem.copyForwards(u8, buf[0 .. len - off], buf[off..len]);
            len -= off;
        }
    }
    return false;
}

fn scriptedServer(listener: *Listener, script: ServerScript, view: *ServerView) void {
    const lfd = listener.server.socket.handle;
    // Shrink the receive window *before* accept: on both macOS and Linux the
    // accepted socket inherits it, so the client's uploads hit backpressure
    // after a predictable amount of audio rather than an unpredictable amount.
    std.posix.setsockopt(lfd, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &std.mem.toBytes(script.recv_buf_bytes)) catch {};

    const cfd: std.posix.socket_t = cfd: {
        var waits: u32 = 0;
        while (true) {
            if (listener.stop.load(.acquire)) return;
            var fds = [_]std.posix.pollfd{.{ .fd = lfd, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&fds, 1) catch return;
            if (n == 0) {
                waits += 1;
                if (waits > accept_deadline_waits) return;
                continue;
            }
            const rc = std.posix.system.accept(lfd, null, null);
            switch (std.posix.errno(rc)) {
                .SUCCESS => break :cfd @intCast(rc),
                .INTR, .AGAIN => continue,
                else => return,
            }
        }
    };
    defer _ = std.posix.errno(std.posix.system.close(cfd));

    // Set O_NONBLOCK on the ACCEPTED socket, explicitly.
    //
    // POSIX does not make `accept` inherit the listener's status flags, and on
    // Linux it demonstrably does not: with only the listener set non-blocking,
    // the accepted socket is blocking, `std.posix.read` here parks instead of
    // returning WouldBlock, and the server thread never gets as far as sending
    // the auth reply. The session then waits for an auth reply that is stuck
    // behind its own reader, times out at the duration cap, and the test fails
    // with `bars=0` and no hint as to why — which is exactly how it failed on CI
    // before this line existed.
    //
    // `proto_fuzz.zig` gets away without it only because its read loop blocks
    // happily until the client writes or hangs up, so the blocking socket never
    // costs it anything. This harness has to *stop* reading for a while and
    // then start again, and only a non-blocking socket can do that.
    {
        var o: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(cfd, std.c.F.GETFL, @as(c_int, 0)))));
        o.NONBLOCK = true;
        _ = std.c.fcntl(cfd, std.c.F.SETFL, @as(c_int, @bitCast(o)));
    }

    // Abort on close (RST, not FIN): this server sends the first FIN, so a clean
    // close parks the port in TIME_WAIT for ~15-30 s and a long test run
    // exhausts the ephemeral range (that is what hung proto_fuzz's deep hunt).
    const li = std.posix.linger{ .onoff = 1, .linger = 0 };
    std.posix.setsockopt(cfd, std.posix.SOL.SOCKET, std.posix.SO.LINGER, &std.mem.toBytes(li)) catch {};
    // Zig does not ignore SIGPIPE for us.
    if (builtin.os.tag == .macos) {
        std.posix.setsockopt(cfd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, &std.mem.toBytes(@as(c_int, 1))) catch {};
    }

    // Handshake: challenge -> (read the 0x80) -> auth ok -> (read the 0x82).
    // These reads are real reads and they matter: the session only reaches
    // .active after the auth reply, and it never starts an interval clock
    // until the config arrives.
    if (!sendFrame(cfd, proto.MSG_AUTH_CHALLENGE, &challengePayload())) return;
    if (!readUntilType(cfd, view, 0x80, 2000)) return;
    if (!sendFrame(cfd, proto.MSG_AUTH_REPLY, &authReplyPayload("kujamba", 8))) return;
    if (!readUntilType(cfd, view, 0x82, 2000)) return;

    const cfg = blackholeConfig{};
    if (!sendFrame(cfd, proto.MSG_CONFIG_CHANGE_NOTIFY, &configPayload(cfg.bpm, cfg.bpi))) return;

    // The blackhole: no read at all. Whatever the client uploads now piles up
    // in the kernel until the send side would block.
    if (script.blackhole_ms > 0) _ = sleepMs(script.blackhole_ms);

    // Drain to the end of the script's life. Whatever the client managed to
    // push while we were not reading arrives now.
    var waited_ms: u32 = 0;
    const drain_ms = script.lifetime_ms;
    var scratch: [16384]u8 = undefined;
    while (waited_ms < drain_ms and !listener.stop.load(.acquire)) {
        const n = std.posix.read(cfd, &scratch) catch |e| switch (e) {
            error.WouldBlock => {
                _ = sleepMs(1);
                waited_ms += 1;
                continue;
            },
            else => return,
        };
        if (n == 0) {
            view.saw_eof = true;
            return;
        }
        view.bytes_read += n;
    }
}

/// One framed message. Returns false on a dead connection.
///
/// Note the two halves are written with `writeAllFrame`, not `rawSend`. The
/// first version of this used `rawSend(...) != null`, which is wrong in a way
/// that only shows up on a loaded machine: `rawSend` returns `0` for EAGAIN as
/// well as for a real write, so a partial write looked like success. A 5-byte
/// header followed by a body that never arrived leaves the peer inside
/// `ensureBuffered`, waiting on a message it was told was longer than the bytes
/// that followed — so the client never sees the `0x02` and the session idles to
/// its duration cap. Measured on CI as `msgs_recv=2` with `bars=0` and no other
/// symptom: the handshake appeared to work, because it did. The retry below is
/// bounded rather than a `while (true)`, because the harness must not be able to
/// hang the test it exists to measure.
fn sendFrame(fd: std.posix.socket_t, mtype: u8, payload: []const u8) bool {
    var hdr: [5]u8 = undefined;
    hdr[0] = mtype;
    std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
    return writeAllFrame(fd, &hdr) and writeAllFrame(fd, payload);
}

/// `sendFrameEagainSpins` retries of 1 ms before giving up on a full socket.
const sendFrameEagainSpins: u32 = 2000;

fn writeAllFrame(fd: std.posix.socket_t, bytes: []const u8) bool {
    var off: usize = 0;
    var spins: u32 = 0;
    while (off < bytes.len) {
        const n = rawSend(fd, bytes[off..]) orelse return false;
        if (n == 0) {
            spins += 1;
            if (spins > sendFrameEagainSpins) return false;
            _ = sleepMs(1);
            continue;
        }
        off += n;
        spins = 0;
    }
    return true;
}

fn rawSend(fd: std.posix.socket_t, bytes: []const u8) ?usize {
    if (bytes.len == 0) return 0;
    const rc = switch (builtin.os.tag) {
        .macos => std.posix.system.write(fd, bytes.ptr, bytes.len),
        else => std.posix.system.send(fd, bytes.ptr, bytes.len, std.posix.MSG.NOSIGNAL),
    };
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        // A non-blocking socket with a full buffer: "try again", not "dead".
        .INTR, .AGAIN => return 0,
        else => return null,
    }
}

/// Read whatever is available for up to `budget_ms`, counting bytes. Returns
/// false if the connection died.
fn drain(fd: std.posix.socket_t, view: *ServerView, budget_ms: u32) bool {
    var scratch: [16384]u8 = undefined;
    var waited: u32 = 0;
    while (waited <= budget_ms) {
        const n = std.posix.read(fd, &scratch) catch |e| switch (e) {
            error.WouldBlock => {
                _ = sleepMs(1);
                waited += 1;
                continue;
            },
            else => return false,
        };
        if (n == 0) {
            view.saw_eof = true;
            return true;
        }
        view.bytes_read += n;
    }
    return true;
}

// #14: a frame larger than the whole socket is refused, not waited on.
//
// `Conn.writable()` answers "could you take a write at all?" and
// `sendMessageBounded` answers "could you take THIS frame?". They are not the
// same question, and only the second one is safe to act on: a socket with room
// for a few hundred bytes says yes to the first and no to the second, and
// trusting the first would put a frame header on the wire followed by a
// fragment of its body — leaving the peer holding a message it has been told is
// longer than the bytes that followed, which on a stream with no resync marker
// is the end of the session. `sendMessageBounded` therefore does not consult
// `writable()` at all: it measures the room itself.
//
// Whether `writable()` happens to be true in a given half-full state is a
// kernel flow-control decision and is not asserted here. What must always hold
// is the outcome: a frame that cannot go out whole is refused, promptly, and a
// small control message on the same socket still does.
test "#14: a frame bigger than the whole socket is refused, not waited on" {
    const io = harnessIo();
    const fds = try socketPair(8192);
    defer {
        _ = std.posix.errno(std.posix.system.close(fds[0]));
        _ = std.posix.errno(std.posix.system.close(fds[1]));
    }
    var conn = net.Conn{ .io = io, .fd = fds[0] };

    var payload: [16367]u8 = undefined;
    @memset(&payload, 0x5A);
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    _ = fillUntilBlocked(fds[0], &junk);

    // 16372 bytes of frame into a socket whose whole buffer is 8192: this can
    // never succeed, however long anyone waits for it.
    const t0 = clock.nowNs(io);
    const outcome = try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_WRITE, &payload, 0);
    const elapsed_ns = clock.nowNs(io) - t0;
    std.debug.print(
        \\  #14 oversize  16 KiB frame into an 8 KiB socket: {any} in {d} ms
        \\
    , .{ outcome, @divTrunc(elapsed_ns, std.time.ns_per_ms) });
    try std.testing.expectEqual(net.SendOutcome.declined, outcome);
    try std.testing.expect(elapsed_ns < 500 * std.time.ns_per_ms);

    // the session still talks to the server on the same socket: control
    // messages are small, and a session that could not answer the server at all
    // would be a worse failure than a dropped bar
    var sink: [65536]u8 = undefined;
    _ = drainSocket(fds[1], &sink);
    const small = [_]u8{0x01} ** 256;
    try std.testing.expectEqual(net.SendOutcome.sent, try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_BEGIN, &small, 0));
}

/// A bounded sleep on the io clock. Zig 0.16 took `std.Thread.sleep` away, so
/// this goes through `Clock.awake`, the same clock `clock.zig` reads the
/// session's timing from — which is also why the blackhole is measured on the
/// monotonic ("awake") clock and not on wall time: a wall-clock jump mid-test
/// would otherwise shorten or lengthen the window it is trying to create.
fn sleepMs(ms: u32) bool {
    const io = harnessIo();
    const d: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake };
    d.sleep(io) catch {};
    return true;
}

// ---- payload builders --------------------------------------------------------
// Hand-rolled like proto_fuzz.zig's: the harness must not share a builder bug
// with the code it is measuring.

fn challengePayload() [16]u8 {
    var out: [16]u8 = undefined;
    @memcpy(out[0..8], "\x01\x23\x45\x67\x89\xAB\xCD\xEF");
    // caps 0x300 -> keepalive 3 s; current protocol version
    std.mem.writeInt(u32, out[8..12], 0x00000300, .little);
    std.mem.writeInt(u32, out[12..16], proto.PROTO_VER_CUR, .little);
    return out;
}

fn authReplyPayload(user: []const u8, maxchan: u8) [64]u8 {
    var out = std.mem.zeroes([64]u8);
    out[0] = 1; // ok
    const n = @min(user.len, out[1..].len - 1);
    @memcpy(out[1..][0..n], user[0..n]);
    out[1 + n] = maxchan;
    return out;
}

fn configPayload(bpm: u16, bpi: u16) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], bpm, .little);
    std.mem.writeInt(u16, out[2..4], bpi, .little);
    return out;
}

// ---- the driver --------------------------------------------------------------

/// The tempo the scripted server hands out: 300 bpm / 4 bpi at 48 kHz is a
/// perfectly ordinary 800 ms bar.
///
/// An earlier version of this harness used 6000 bpm / 1 bpi — a 10 ms bar —
/// on the theory that a smaller bar is a faster test. It is a much more
/// interesting claim than that, and it is in ISSUES.md: the run loop polls for
/// readability every 20 ms and finalizes at most one interval per pass, so a bar
/// shorter than the poll cannot be sustained. Measured: 126 bars in 4 s, 2231 ms
/// of accumulated drift, and a bounded slew firing on every single one and still
/// losing ground. Worth knowing; not worth a test that depends on it.
pub const blackholeConfig = struct { bpm: u16 = 300, bpi: u16 = 4 };

const TimedRun = struct {
    stats: session.Stats,
    server: ServerView,
    /// wall ns the session spent inside `run()`, so a test can compare the
    /// elapsed time against the grid it should have walked
    elapsed_ns: u64,
};

fn runScriptedSession(script: ServerScript, opts: session.Options) !TimedRun {
    const alloc = std.testing.allocator;
    const io = harnessIo();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = Listener.init(try std.Io.net.IpAddress.listen(&addr, io, .{}), io);
    defer listener.close();

    var view = ServerView{};
    const srv = try std.Thread.spawn(.{}, scriptedServer, .{ &listener, script, &view });
    var opts_mut = opts;
    opts_mut.host = "127.0.0.1";
    opts_mut.port = listener.port();
    var s = session.Session.init(alloc, io, opts_mut) catch |e| {
        listener.close();
        srv.join();
        return e;
    };
    defer {
        s.deinit(); // closes the session socket -> the server's read sees EOF
        srv.join();
    }
    s.log.quiet = true;

    const t0 = clock.nowNs(io);
    // A failed session still has a verdict worth reading: this is the whole
    // reason runDispatchStep hands Stats back (see proto_fuzz.zig).
    const stats = s.run() catch s.stats;
    const elapsed = clock.nowNs(io) - t0;
    return .{ .stats = stats, .server = view, .elapsed_ns = @intCast(elapsed) };
}

/// A tone, not silence. This matters: `.silence` encodes to a handful of bytes
/// per bar, so a silent source never fills a socket buffer and the backpressure
/// path would look unreachable. A tone at 440 Hz encodes to tens of KB per bar.
fn toneSource() session.Source {
    return .{ .tone = .{ .freq = 440.0, .amp = 0.5 } };
}

// ---- socket helpers ---------------------------------------------------------

/// A connected socket pair whose client end has a deliberately small send
/// buffer, both ends non-blocking. See the #14 tests for why this and not a
/// loopback listener.
fn socketPair(buf_bytes: i32) ![2]std.posix.socket_t {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(@intCast(std.posix.AF.UNIX), @intCast(std.posix.SOCK.STREAM), 0, &fds);
    if (std.posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    std.posix.setsockopt(fds[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &std.mem.toBytes(buf_bytes)) catch {};
    std.posix.setsockopt(fds[1], std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &std.mem.toBytes(buf_bytes)) catch {};
    for (fds) |fd| {
        var o: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)))));
        o.NONBLOCK = true;
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(o)));
    }
    return fds;
}

/// Fill a non-blocking socket until `write` returns anything but SUCCESS.
/// Returns the bytes it took, so a test can prove the pipe really was full.
fn fillUntilBlocked(fd: std.posix.socket_t, buf: []const u8) usize {
    var total: usize = 0;
    while (true) {
        const rc = std.posix.system.write(fd, buf.ptr, buf.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => total += @intCast(rc),
            else => return total,
        }
    }
}

// #14: the half-full socket — the case that tore frames.
//
// Every other #14 test here fills the buffer *completely*, so `writable()` is
// false and the send is refused with zero bytes written. That is the clean-drop
// path, and it is the easy one. The realistic slow-peer state is a buffer that
// is partly drained: POLLOUT is set as soon as *one* byte is free, so the gate
// says yes, and a 16 KiB frame into 6 KiB of room used to put a complete
// 16 KB-declaring header plus 5995 bytes of payload on the wire before giving
// up. The peer then frames by the declared length, so it eats the next bar's
// bytes as this frame's missing tail and parses whatever follows as a header
// from mid-stream: one dropped bar's worth of tidiness bought a session that
// uploads nothing ever again.
//
// Measured on this exact code before the fix: refused, and 6000 bytes on the
// wire. The assertion below is the whole point — *zero* is the only acceptable
// number here, and it is an assertion about bytes rather than about a return
// value, because a return value is what was wrong last time.
//
// A socketpair, deliberately. The test needs a buffer with genuine room in it
// that still cannot take a frame, and it needs that to be true *exactly*, on
// every platform, every run. Over TCP it is neither: Darwin frees send space in
// 16 KiB quanta and reports the queue with `SO_NWRITE`, which lags the space
// actually available, so the "half full" state settled at 16332 bytes on one run
// and was unreachable on the next. A socketpair's `SO_SNDBUF` is exact on both
// platforms, and a capacity smaller than one frame is a state no kernel
// accounting can argue its way out of.
test "#14: a half-full socket declines the frame with zero bytes on the wire" {
    const io = harnessIo();
    const fds = try socketPair(8192);
    defer {
        _ = std.posix.errno(std.posix.system.close(fds[0]));
        _ = std.posix.errno(std.posix.system.close(fds[1]));
    }
    var conn = net.Conn{ .io = io, .fd = fds[0] };

    // Saturate, then hand back a fixed slice: a buffer with some room left in
    // it, and not enough for the frame. That is the state the bug needs and the
    // one no other test here reaches.
    //
    // `writable()` is printed but deliberately **not** asserted. Its whole
    // character is that it is a coarse gate — "at least one byte free" — and how
    // coarse is the kernel's business: an earlier cut asserted it here and passed
    // on macOS while failing on Linux, where a socket with 4096 bytes free out
    // of a 16384-byte buffer does not report itself writable. The property the
    // test actually needs is the one below it, and that is stated in bytes
    // rather than in the kernel's opinion.
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    const absorbed = fillUntilBlocked(fds[0], &junk);
    var sink: [65536]u8 = undefined;
    const drained = drainSocket(fds[1], sink[0..4096]);
    try std.testing.expect(drained > 0);

    var payload: [16367]u8 = undefined;
    @memset(&payload, 0x5A);
    const room = conn.sendRoom().?;
    std.debug.print(
        \\  #14 half-full  {d} of {d} bytes queued, {d} reported free, POLLOUT={any}, {d}-byte frame
        \\
    , .{ absorbed - drained, absorbed, room, conn.writable(), payload.len + 5 });
    // room to spare, and not enough for the frame: exactly the condition in
    // which the old code put a header on the wire and a fragment of its body
    try std.testing.expect(room > 0);
    try std.testing.expect(room < 5 + payload.len);

    const outcome = try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_WRITE, &payload, session.upload_write_budget_ms);
    std.debug.print("  -> {any}\n", .{outcome});
    try std.testing.expectEqual(net.SendOutcome.declined, outcome);

    // The assertion that was missing: not one byte of that frame crossed the
    // wire. A lone header is already enough to do the damage, because the peer
    // will believe the 16 KiB that follows it.
    //
    // Counted against the junk rather than a fixed number: everything the
    // harness wrote, and nothing else, may be read back.
    var seen: usize = drained;
    var stalls: u32 = 0;
    while (seen < absorbed and stalls < 2000) {
        const n = std.posix.read(fds[1], sink[0..]) catch |e| switch (e) {
            error.WouldBlock => {
                stalls += 1;
                _ = sleepMs(1);
                continue;
            },
            else => break,
        };
        if (n == 0) break;
        seen += n;
        stalls = 0;
    }
    std.debug.print("  peer received {d} bytes; the harness wrote {d}, so the frame contributed {d}\n", .{ seen, absorbed, seen -| absorbed });
    try std.testing.expectEqual(absorbed, seen);
}

// #14: the same claim end to end, on the socket the session actually uses, and
// stated in the way that is true whether the gate declines the frame or accepts
// it.
//
// A torn frame does not announce itself. There is no resync marker, so the only
// way to see one is to parse the peer's byte stream exactly as the server's
// parser would and notice that it no longer lands on a frame boundary. That is
// what this does, and it is strictly stronger than checking a return value: it
// does not care *how* the outcome was reached, only that the stream is still
// framed afterwards.
//
// A real TCP pair rather than a socketpair, because on Darwin a unix socket
// keeps its buffer on the receiving end and `SO_NWRITE` on the writer stays 0 —
// the queue depth is simply not observable there, so a socketpair would exercise
// the fallback rather than the gate.
test "#14: a refused frame leaves the peer's byte stream still frame-aligned" {
    const io = harnessIo();
    const fds = try tcpPairBuffered(65536, 4096);
    defer {
        _ = std.posix.errno(std.posix.system.close(fds[0]));
        _ = std.posix.errno(std.posix.system.close(fds[1]));
    }
    var conn = net.Conn{ .io = io, .fd = fds[0] };

    // A socketpair's exact accounting is what the previous test uses; here the
    // sender is loaded with *valid frames* so that the peer's stream can be
    // parsed, and so that a torn upload would be visible as a boundary error
    // rather than as junk.
    var frame_buf: [13]u8 = undefined;
    const frame = @constCast(buildFrame(&frame_buf, 0x01, 8, 0x7E));

    var payload: [16367]u8 = undefined;
    @memset(&payload, 0x5A);
    var queued: usize = 0;
    const head = try std.testing.allocator.alloc(u8, 400_000);
    defer std.testing.allocator.free(head);
    var head_len: usize = 0;
    const room = waitForPartialRoom(&conn, fds[1], 5 + payload.len, frame, &queued, head, &head_len);
    const outcome = try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_WRITE, &payload, session.upload_write_budget_ms);
    std.debug.print(
        \\  #14 aligned  {d} junk frames queued, {d} free, {d} helper bytes, {d}-byte frame -> {any}
        \\
    , .{ queued / frame.len, room, head_len, payload.len + 5, outcome });
    // The one outcome that is not allowed. `.declined` and `.sent` are both
    // safe; only a torn frame desynchronises the peer.
    try std.testing.expect(outcome != .partial);

    // Read the peer's stream and parse it the way the server's parser does:
    // one type byte, a little-endian length, that many payload bytes, repeat.
    // A partial frame shows up as a length that runs past the end of what
    // arrived, or as a trailing tail too short to be a header.
    //
    // The two buffers are one stream: the helper above already read the first
    // `head_len` bytes off the wire, so they are put back in front before
    // parsing.
    const sink = try std.testing.allocator.alloc(u8, 512_000);
    defer std.testing.allocator.free(sink);
    var seen: usize = 0;
    var stalls: u32 = 0;
    // Read until the peer has everything the sender wrote — exactly `queued`
    // bytes, because the frame contributed none. A fixed stall budget is the
    // wrong stopping rule: on a loaded runner the backlog can sit unsent for
    // longer than any budget you pick, and stopping early truncates the stream
    // mid-frame and reports a torn frame that never happened. Knowing the
    // expected total removes the question.
    while (head_len + seen < queued and head_len + seen < sink.len and stalls < 2000) {
        const n = std.posix.read(fds[1], sink[head_len + seen ..]) catch |e| switch (e) {
            // Not "no more data", just "not right now": the sender still has
            // bytes in flight and will hand them over as ACKs come back.
            error.WouldBlock => {
                stalls += 1;
                _ = sleepMs(1);
                continue;
            },
            else => break,
        };
        if (n == 0) break;
        seen += n;
        stalls = 0;
    }
    // The two buffers are one stream, and they are already in place: the read
    // above landed at `head_len + seen` precisely so that the helper's bytes go
    // back in front without moving anything. There used to be a `copyForwards`
    // here to do that, left over from when the read started at `seen` — and it
    // was not a no-op, it overwrote the freshly-read bytes with the first `seen`
    // bytes of the same buffer. macOS hid it because `head_len` is 0 there, so
    // the copy became a self-copy; on Linux the helper drains a byte or two
    // before the room appears, and the parser then read a length of 0x01010000
    // out of the middle of the stream. Two platforms, one copy-paste, and only
    // the one with a non-zero `head_len` could see it.
    @memcpy(sink[0..head_len], head[0..head_len]);
    const total = head_len + seen;
    try std.testing.expectEqual(queued, total); // the frame contributed nothing

    // The junk is whole frames plus at most one partial frame, by construction,
    // so the frame count and the residue are both known in advance. A torn
    // *upload* is what would break them: its declared length would run past the
    // end of what arrived, eating the frames behind it, so the walk would
    // report fewer frames and a larger residue than went in.
    const residue = total % frame.len;
    const w = walkFrames(sink[0..total]);
    std.debug.print("  {d} bytes walked as {d} whole frames, {d}-byte filler remainder\n", .{ total, w.frames, w.residue });
    try std.testing.expectEqual(queued / frame.len, w.frames);
    try std.testing.expectEqual(residue, w.residue);
    try std.testing.expect(w.frames > 0);
}

/// A connected TCP pair on loopback whose client end has a pinned send buffer
/// and a peer that reads nothing until told otherwise.
///
/// A TCP pair rather than a socketpair specifically because of what the atomicity
/// gate can see. On Linux `TIOCOUTQ` reports the send queue for both AF_UNIX and
/// AF_INET, but on Darwin a unix socket keeps its buffer on the *receiving* end:
/// `SO_NWRITE` on the writer stays 0 however much it has queued, measured. A
/// socketpair would therefore make the gate look like it was working while
/// actually declining to answer, and a test written against one would be
/// measuring nothing. TCP is also what the session really uses, so it is the
/// socket whose accounting is worth trusting.
///
/// Everything is non-blocking and the accept is retried on this thread rather
/// than handed to a helper thread: a thread would have to outlive the call to
/// keep the peer from reading, and then the test would pay for it at `join`.
fn tcpPair(snd_buf_bytes: i32) ![2]std.posix.socket_t {
    return tcpPairBuffered(snd_buf_bytes, 4096);
}

fn tcpPairBuffered(snd_buf_bytes: i32, rcv_buf_bytes: i32) ![2]std.posix.socket_t {
    const lfd: std.posix.socket_t = @intCast(std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP));
    errdefer _ = std.posix.errno(std.posix.system.close(lfd));
    var lo: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(lfd, std.c.F.GETFL, @as(c_int, 0)))));
    lo.NONBLOCK = true;
    _ = std.c.fcntl(lfd, std.c.F.SETFL, @as(c_int, @bitCast(lo)));

    var sa: std.posix.sockaddr.in = std.mem.zeroes(std.posix.sockaddr.in);
    sa.family = std.posix.AF.INET;
    sa.port = 0; // let the kernel choose
    sa.addr = @bitCast(@as([4]u8, .{ 127, 0, 0, 1 }));
    if (std.posix.errno(std.posix.system.bind(lfd, @ptrCast(&sa), @sizeOf(@TypeOf(sa)))) != .SUCCESS) return error.BindFailed;
    if (std.posix.errno(std.posix.system.listen(lfd, 1)) != .SUCCESS) return error.ListenFailed;
    var bound: std.posix.sockaddr.in = undefined;
    var blen: std.posix.socklen_t = @sizeOf(@TypeOf(bound));
    _ = std.posix.system.getsockname(lfd, @ptrCast(&bound), &blen);

    const cfd: std.posix.socket_t = @intCast(std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP));
    errdefer _ = std.posix.errno(std.posix.system.close(cfd));
    var co: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(cfd, std.c.F.GETFL, @as(c_int, 0)))));
    co.NONBLOCK = true;
    _ = std.c.fcntl(cfd, std.c.F.SETFL, @as(c_int, @bitCast(co)));
    std.posix.setsockopt(cfd, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &std.mem.toBytes(snd_buf_bytes)) catch {};
    switch (std.posix.errno(std.posix.system.connect(cfd, @ptrCast(&bound), @sizeOf(@TypeOf(bound))))) {
        .SUCCESS, .INPROGRESS, .INTR => {},
        else => return error.ConnectFailed,
    }

    var afd: std.posix.socket_t = -1;
    var waited: u32 = 0;
    while (afd < 0 and waited < 2000) {
        var ca: std.posix.sockaddr.in = undefined;
        var cl: std.posix.socklen_t = @sizeOf(@TypeOf(ca));
        const a = std.posix.system.accept(lfd, @ptrCast(&ca), &cl);
        switch (std.posix.errno(a)) {
            .SUCCESS => afd = @intCast(a),
            else => {
                waited += 1;
                _ = sleepMs(1);
            },
        }
    }
    _ = std.posix.errno(std.posix.system.close(lfd));
    if (afd < 0) return error.AcceptFailed;
    var ao: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(afd, std.c.F.GETFL, @as(c_int, 0)))));
    ao.NONBLOCK = true;
    _ = std.c.fcntl(afd, std.c.F.SETFL, @as(c_int, @bitCast(ao)));
    // Pinned so the peer cannot quietly absorb the whole sender queue: see
    // `waitForPartialRoom`. Loopback has been measured ignoring SO_RCVBUF on a
    // *listening* socket, which is why the handoff accepts and this is set on the
    // accepted fd instead.
    std.posix.setsockopt(afd, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &std.mem.toBytes(rcv_buf_bytes)) catch {};
    return .{ cfd, afd };
}

/// Drive a saturated connection into a *partially* full state — some room, less
/// than `frame_bytes` — and return that room, or 0 if it never got there.
///
/// This is the state the bug lives in, and getting to it took three attempts
/// worth recording, because all three looked reasonable and all three were
/// wrong.
///
/// Letting it settle on its own does not work. With a stock peer the kernel
/// pushes everything the peer's receive buffer will take and the room goes from
/// 0 to the full 81660 between two samples: measured, the same test settling at
/// 52 bytes on one run and at capacity on the next, with nothing different in
/// between.
///
/// Pinning the peer's receive buffer small does not work either — it just inverts
/// the problem. The peer stops absorbing, the sender never gets an ACK, and the
/// room sits at 0 for 400 000 straight samples.
///
/// What works is to make the peer give back exactly one byte per sample, so the
/// sender's room grows one byte at a time and the loop stops in the band rather
/// than leaping over it. `getsockopt` costs about a microsecond, so a few hundred
/// thousand samples is a couple of seconds of very fine resolution.
/// What walking a NINJAM byte stream found: whole frames, plus the bytes left
/// over that did not make one.
pub const Walk = struct { frames: usize = 0, residue: usize = 0 };

/// Walk a NINJAM byte stream exactly as the server's parser does: one type byte,
/// a little-endian length, that many payload bytes, repeat. There is no resync
/// marker, so this is the only reading of the stream there is.
///
/// A frame whose declared length runs past the end of what arrived is a *torn*
/// frame, and that is the failure #14 exists to prevent. It cannot be reported
/// as an error here — from inside the walk it is indistinguishable from a
/// stream that simply stopped — so it shows up as a frame count and a residue
/// that disagree with what went in, which is what the callers below assert.
pub fn walkFrames(bytes: []const u8) Walk {
    var w: Walk = .{};
    var off: usize = 0;
    while (off < bytes.len) {
        if (bytes.len - off < 5) break; // too short for even a header
        const len = std.mem.readInt(u32, bytes[off + 1 ..][0..4], .little);
        if (len > net.max_payload) break; // not a header we can believe
        if (bytes.len - off < 5 + @as(usize, len)) break; // the frame runs past the end
        w.frames += 1;
        off += 5 + @as(usize, len);
    }
    w.residue = bytes.len - off;
    return w;
}

/// Build a well-formed frame of `payload_len` bytes in `out`.
fn buildFrame(out: []u8, mtype: u8, payload_len: usize, fill: u8) []const u8 {
    out[0] = mtype;
    std.mem.writeInt(u32, out[1..5], @intCast(payload_len), .little);
    @memset(out[5 .. 5 + payload_len], fill);
    return out[0 .. 5 + payload_len];
}

// #14: the frame walk, on inputs where the answer is not in doubt.
//
// The socket tests that use this have to manufacture their own stream, and a
// manufactured stream is a source of false alarms — one version of the alignment
// test reported a torn frame that its own filler had put there. So the walk
// itself is checked here on byte patterns with no sockets in them: a clean run of
// frames, a run with a truncated tail, and the actual shape of the bug, where a
// header promises 16 KiB, 6 KiB arrive, and a perfectly good frame follows. That
// last one is the point of the whole exercise: it must *not* look like a clean
// stream, and a test that cannot tell the difference is not testing anything.
test "#14: a torn frame is visible to the frame walk" {
    // a clean run of three 8-byte frames
    var clean: [3 * 13]u8 = undefined;
    for (0..3) |i| _ = buildFrame(clean[i * 13 ..][0..13], 0x01, 8, 0x7E);
    const a = walkFrames(&clean);
    try std.testing.expectEqual(@as(usize, 3), a.frames);
    try std.testing.expectEqual(@as(usize, 0), a.residue);

    // the same, with a frame cut short — the filler's permitted remainder
    var truncated: [3 * 13 + 6]u8 = undefined;
    for (0..3) |i| _ = buildFrame(truncated[i * 13 ..][0..13], 0x01, 8, 0x7E);
    @memset(truncated[3 * 13 ..], 0x7E);
    const b = walkFrames(&truncated);
    try std.testing.expectEqual(@as(usize, 3), b.frames);
    try std.testing.expectEqual(@as(usize, 6), b.residue);

    // And the bug itself. A frame is torn — its header promises 8 bytes and 4
    // arrive — and then two perfectly good frames follow it, as the next two
    // bars would.
    //
    // The walk cannot say "that was torn": from where it stands, a frame with
    // more bytes after it is just a frame. What it does is *disagree with the
    // sender's account of the stream*, and the disagreement is the whole
    // symptom. Four complete frames went in. The walk reports fewer, because the
    // good frame behind the tear was swallowed as the torn frame's missing
    // payload — which is exactly what the server would do, and why every message
    // after a single torn frame is garbage.
    var torn: [2 * 13 + 5 + 4 + 2 * 13]u8 = undefined;
    var t: usize = 0;
    for (0..2) |_| {
        _ = buildFrame(torn[t..][0..13], 0x01, 8, 0x7E);
        t += 13;
    }
    torn[t] = 0x84;
    std.mem.writeInt(u32, torn[t + 1 ..][0..4], 8, .little); // promises 8
    @memset(torn[t + 5 ..][0..4], 0x5A); // delivers 4
    t += 5 + 4;
    for (0..2) |_| {
        _ = buildFrame(torn[t..][0..13], 0x01, 8, 0x7E);
        t += 13;
    }

    const c = walkFrames(torn[0..t]);
    try std.testing.expect(c.frames < 4); // four went in
    try std.testing.expect(c.residue > 0); // and it did not end on a boundary
    std.debug.print("  torn frame: 4 whole frames in, {d} frames and a {d}-byte tail out\n", .{ c.frames, c.residue });

    // And the case the *length* check exists for, which is a different failure
    // from the one above: the stream simply ends in the middle of a frame whose
    // header is perfectly believable. Here it declares 8 payload bytes and 3
    // arrive. That is what a truncated read looks like, and it is also exactly
    // what the alignment test's filler can leave behind, so the residue it
    // accounts for is this one.
    //
    // Worth its own case because the two checks are not redundant. The other
    // cases here all trip the "declared length is not believable" check first,
    // which left the length check with no test at all — a mutation removing it
    // survived, and the walk then stepped past the end of the buffer entirely.
    var cut: [2 * 13 + 8]u8 = undefined;
    var c_off: usize = 0;
    for (0..2) |_| {
        _ = buildFrame(cut[c_off..][0..13], 0x01, 8, 0x7E);
        c_off += 13;
    }
    cut[c_off] = 0x84;
    std.mem.writeInt(u32, cut[c_off + 1 ..][0..4], 8, .little);
    @memset(cut[c_off + 5 ..][0..3], 0x5A);
    c_off += 8;
    const d = walkFrames(cut[0..c_off]);
    try std.testing.expectEqual(@as(usize, 2), d.frames);
    try std.testing.expectEqual(@as(usize, 8), d.residue);
}

/// Fill a socket with whole copies of `frame`, writing at most one partial
/// frame and only ever as the very last thing on the wire. Returns the total.
///
/// `fillUntilBlocked` is the obvious thing to reach for and it is wrong here: it
/// stops on a *short* write without stopping the loop, so the stream can end up
/// as whole frames, a 7-byte fragment, then more whole frames — permanently
/// misaligned, with the parser then reading a length out of the wrong byte and
/// reporting a torn frame that the test had manufactured. Stopping at the first
/// short write makes the stream whole frames followed by at most one remainder,
/// which is an exact quantity the caller can account for.
fn fillWithWholeFrames(fd: std.posix.socket_t, frame: []u8) usize {
    var total: usize = 0;
    while (true) {
        const n = std.posix.system.write(fd, frame.ptr, frame.len);
        if (std.posix.errno(n) != .SUCCESS) return total;
        const w: usize = @intCast(n);
        total += w;
        if (w < frame.len) return total; // a partial frame, and nothing after it
    }
}

fn waitForPartialRoom(conn: *net.Conn, peer: std.posix.socket_t, frame_bytes: usize, fill: []u8, junk_out: *usize, head: []u8, head_len: *usize) usize {
    junk_out.* = fillWithWholeFrames(conn.fd, fill);
    var spins: u32 = 0;
    // Drain first, then look. The order matters more than it looks: a
    // check-first loop returns having consumed nothing on any platform where
    // one byte of room appears immediately, and consumes a few on the ones
    // where it does not — which makes the caller's bookkeeping correct on one
    // platform and silently untested on the other. A copy-paste bug lived
    // exactly in that gap for two CI runs. Draining first means `head_len` is
    // non-zero everywhere, so there is one code path and it is the hard one.
    while (spins < 400_000) : (spins += 1) {
        if (head_len.* < head.len) {
            const n = std.posix.read(peer, head[head_len.*..][0..1]) catch 0;
            head_len.* += n;
        }
        const room = conn.sendRoom() orelse return 0;
        if (room > 0 and room < frame_bytes) return room;
    }
    return 0;
}

fn drainSocket(fd: std.posix.socket_t, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

fn baseOptions() session.Options {
    return .{
        .user = "kujamba",
        .pass = "timing",
        .srate = 48000,
        .channel_names = &.{"kujamba"},
        .source = toneSource(),
        .out_dir = timing_out_dir,
        .transcript_path = null,
        .duration_ms = 4000,
    };
}

// ---- the measurement --------------------------------------------------------

// #14: measure the backpressure hazard with a peer that stops reading.
//
// This test existed before the fix and its result is the number the fix is
// judged against, so it is kept as a *reporting* test rather than deleted: it
// prints the stall it observed so a regression shows up as a changed number
// rather than only as a red assertion.
//
// Read the "max stall" line together with the caveat below it. On macOS
// loopback the peer going quiet does **not** actually produce backpressure, so
// this number measures the run loop's own poll granularity, not the hazard.
// The hazard's real number is the next test.
test "MEASURE #14: a slow peer never stalls the audio clock" {
    // 2 s of silence from the server, inside a 4 s session.
    const run = try runScriptedSession(.{ .blackhole_ms = 2000, .lifetime_ms = 5000 }, baseOptions());

    const stall_ms = run.stats.upload_stall_ns / std.time.ns_per_ms;
    std.debug.print(
        \\
        \\  #14 loopback  blackhole=2000ms  session={d:.0}ms  bars={d} (dropped {d})
        \\                 max stall inside one interval's upload section = {d} ms
        \\                 server read {d} bytes of {d} uploaded
        \\                 drift={d}ms  max|drift|={d}ms  corrections={d}
        \\                 msgs_recv={d} msgs_sent={d} fail="{s}"
        \\
    , .{
        @as(f64, @floatFromInt(run.elapsed_ns)) / 1e9 * 1000.0,
        run.stats.intervals_uploaded,
        run.stats.intervals_dropped,
        stall_ms,
        run.server.bytes_read,
        run.stats.upload_bytes,
        @divTrunc(run.stats.drift_ns, @as(i64, std.time.ns_per_ms)),
        run.stats.max_abs_drift_ns / std.time.ns_per_ms,
        run.stats.clock_corrections,
        run.stats.msgs_recv,
        run.stats.msgs_sent,
        run.stats.failText(),
    });

    // The handshake has to have completed before any of the timing numbers mean
    // anything. Asserted first, and on its own, so a platform difference that
    // stops the session going live fails here — naming the cause — rather than
    // three assertions later as an inexplicable `bars=0`.
    try std.testing.expectEqual(@as(u64, 3), run.stats.msgs_recv); // challenge, auth reply, config

    // Deliberately NOT asserted: how many bars it produced. That number is the
    // runner's encode throughput, and this test was failed by CI three times
    // over it — 4 bars on a workstation, 1 on a loaded macOS runner, 0 on a
    // slower one, same code. A floor that has to be re-tuned per machine is a
    // test measuring the machine. The claim it was reaching for — the clock
    // keeps walking through refused uploads — is asserted deterministically in
    // `session.zig`, which drives `finalizeInterval` twelve times against a
    // blocked socket and counts.
    //
    // What this harness is really for is the integration it cannot get any
    // other way: a real TCP handshake through `Session.run`, through the `0x02`
    // re-anchor, `advanceAudio`'s encode lead, `finalizeInterval` and the
    // bounded writes — with the peer away for two seconds of it.
    //
    // "It came back" is therefore asserted, generously. The pre-fix failure was
    // an unbounded block inside `finalizeInterval`, which is a hang, and a hang
    // blows a duration cap by an order of magnitude.
    try std.testing.expect(run.elapsed_ns < 10 * std.time.ns_per_s);
    // nothing was lost, so nothing was dropped: on loopback the kernel simply
    // never ran out of buffer
    try std.testing.expectEqual(@as(u64, 0), run.stats.intervals_dropped);
    try std.testing.expect(run.server.bytes_read > 0);
    // the upload section never came close to a second long. Pre-fix it had no
    // bound at all (a poll loop that discarded its timeout) and a re-armed
    // 1000 ms budget returns in ~1002 ms, so this separates the two while
    // leaving room for a scheduling spike on a loaded runner.
    try std.testing.expect(run.stats.upload_stall_ns < 500 * std.time.ns_per_ms);
    // #13: the ledger ran. The lag itself is reported above rather than bounded
    // — on an 800 ms bar the dominant term is the run loop's 20 ms poll, and any
    // bound tight enough to be interesting would be a measurement of the runner
    // rather than of the clock. `ServerClock`'s own bounds are asserted where
    // they are implemented, in `instrument.zig`, with no wall clock involved.
}

// #14: the hazard itself, measured on a socket that really does fill.
//
// `scriptedServer` cannot reach this: measured on macOS, a loopback peer that
// stops reading still absorbs **654 KB** with `SO_RCVBUF` pinned to 4096 — the
// loopback path does not honour the receive window the way a routed network
// does. So backpressure on loopback is a slow-peer failure measured in
// seconds, not a jitter failure, and it is not reachable inside a test's
// patience. A socketpair has a genuinely bounded buffer, which is what makes
// the drop path measurable at all — and it is the same `Conn`, the same
// `sendMessageBounded`, only with a smaller pipe.
//
// The before-number, from the same shape before the fix: one 16 KiB
// `sendMessage` against a saturated socketpair did not return after 5000 ms and
// would not have returned at all, because `writeAllRaw`'s EAGAIN branch polls
// for 1000 ms in a loop and throws the result away.
test "#14: a full socket fails the write immediately instead of blocking forever" {
    const io = harnessIo();
    const fds = try socketPair(4096);
    defer {
        _ = std.posix.errno(std.posix.system.close(fds[0]));
        _ = std.posix.errno(std.posix.system.close(fds[1]));
    }
    var conn = net.Conn{ .io = io, .fd = fds[0] };

    var payload: [16367]u8 = undefined;
    @memset(&payload, 0x5A);
    // fill it, with the peer reading nothing
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    const absorbed = fillUntilBlocked(fds[0], &junk);
    try std.testing.expect(absorbed > 0);

    // the zero-timeout gate says no without spending any time finding out
    try std.testing.expect(!conn.writable());

    // and the bounded write gives up rather than waiting out the peer.
    //
    // The budget is the session's own constant, not a literal: this test is
    // what pins `upload_write_budget_ms`, and a literal here would have kept
    // passing when someone turned it back into a second. (It did, once, and
    // this test stayed green for exactly that reason.)
    const t0 = clock.nowNs(io);
    const outcome = try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_WRITE, &payload, session.upload_write_budget_ms);
    const elapsed_ns = clock.nowNs(io) - t0;
    std.debug.print(
        \\  #14 socketpair  socket full after {d} bytes; one 16 KiB upload write returned {any} in {d} ms
        \\
    , .{ absorbed, outcome, @divTrunc(elapsed_ns, std.time.ns_per_ms) });
    try std.testing.expectEqual(net.SendOutcome.declined, outcome);
    // The number: bounded. Pre-fix this call did not return at all, and with a
    // 1000 ms budget it returns in ~1002 ms, so a 500 ms bound separates the
    // two while leaving room for a scheduling spike.
    try std.testing.expect(elapsed_ns < 500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i32, 0), session.upload_write_budget_ms);

    // recovery: drain the peer and the socket takes a write again, which is what
    // makes dropping a bar recoverable rather than fatal.
    //
    // The message here is small on purpose. A 16 KiB frame can *never* go
    // through a 4 KiB send buffer in one call — no amount of waiting changes
    // that — so reusing the big payload here would be testing the pipe, not the
    // recovery. A control-sized frame still goes, which is the part that matters:
    // the session can keep talking to the server after dropping a bar.
    var sink: [65536]u8 = undefined;
    _ = drainSocket(fds[1], &sink);
    try std.testing.expect(conn.writable());
    const small = [_]u8{0x01} ** 256;
    try std.testing.expectEqual(net.SendOutcome.sent, try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_BEGIN, &small, 0));
}

// #14: `sendRoom()` has to be a measurement, not an upper bound.
//
// #14: `sendRoom()` has to be a measurement, not a guess.
//
// The atomicity gate stands or falls on this being the *free* space rather than
// the capacity. If it over-reported — say, returned `SO_SNDBUF` without
// subtracting the queue — every write would pass the gate and every one would
// then be a torn frame, which is precisely the bug the gate exists to stop. If
// it under-reported, writes would be declined that could have succeeded: merely
// a few extra dropped bars, which is the direction worth being wrong in.
test "#14: sendRoom is never optimistic about the room it promises" {
    const io = harnessIo();
    const fds = try tcpPair(65536);
    defer {
        _ = std.posix.errno(std.posix.system.close(fds[0]));
        _ = std.posix.errno(std.posix.system.close(fds[1]));
    }
    var conn = net.Conn{ .io = io, .fd = fds[0] };
    const room = conn.sendRoom() orelse return error.SendRoomUnavailable;
    std.debug.print("  #14 sendRoom  fresh socket reports {d} bytes free\n", .{room});
    try std.testing.expect(room > net.max_payload);

    // The other half of the contract, and the half that catches an optimistic
    // gate: the room it promises has to be room the socket will actually take.
    // A frame sized to fill it must go out *whole* — `.sent`, never `.partial`.
    //
    // This runs on a fresh socket on purpose. Saturated, the room is a moving
    // target: the kernel keeps flushing into the peer's receive buffer, so the
    // measurement taken a moment before the write is not the measurement the
    // gate acts on, and a `.sent` there would be a race won rather than a
    // property proved. On a fresh socket there is nothing in flight and the
    // number is the number.
    const payload_len = @min(room - 5, @as(usize, net.max_payload));
    const payload = try std.testing.allocator.alloc(u8, payload_len);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x3C);
    const outcome = try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_WRITE, payload, session.upload_write_budget_ms);
    std.debug.print("  room {d} promised -> a {d}-byte frame went {any}\n", .{ room, payload_len + 5, outcome });
    try std.testing.expectEqual(net.SendOutcome.sent, outcome);

    // And the gate must not be so eager to refuse that it breaks a healthy
    // session: the same socket takes a control-sized frame straight afterwards.
    //
    // Small on purpose. A second *large* frame would be testing the remaining
    // room, not the gate's disposition, and whether it fits is a question about
    // a live TCP connection and whatever the kernel has done with the first
    // frame's 16 KiB since — which is how this test failed once, under load,
    // with the gate behaving correctly.
    const small = [_]u8{0x01} ** 256;
    try std.testing.expectEqual(net.SendOutcome.sent, try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_BEGIN, &small, session.upload_write_budget_ms));
}

// ---- reconnect (#24) ---------------------------------------------------------
//
// The reconnect tests run a real session against a real loopback server that
// plays scripted per-connection games with it: close cleanly mid-bar (the
// #28 incident's exact symptom — the client reads EndOfStream), go silent (the
// stall detector), or vanish entirely (dial failures). What the tests are
// about, in order: the session rejoins, the `--intervals` cap counts across
// the rejoined sessions instead of restarting, the guid of an abandoned bar is
// re-sent rather than replaced (identity is monotonic; #12's split is what a
// resume stands on), and the resumed payload bytes are identical to an
// uninterrupted run's — the determinism evidence must not move.

/// What the scripted server does with one connection of a reconnect run.
const ReconnectStep = union(enum) {
    /// handshake, config, then close the connection cleanly (FIN, the
    /// EndOfStream shape) once this many 0x83 upload-begins have crossed
    close_after_uploads: u32,
    /// handshake, config, then after the first upload-begin stop sending
    /// entirely (keep READING — the client's own keepalives must not bounce)
    /// for this long, then close. This is the stall-detector trigger.
    silent_ms: u32,
    /// handshake, config, then drain until the client goes away
    drain,
};

const ReconnectScript = struct {
    conns: []const ReconnectStep,
    /// cap on the whole server's life, so a client that never stops cannot
    /// hang the test
    lifetime_ms: u32 = 30_000,
    /// keepalive seconds advertised in the challenge — the client's stall
    /// threshold is this × 3 s, so a fast stall test asks for 1
    keepalive_s: u8 = 3,
    bpm: u16 = 300,
    bpi: u16 = 4,
    /// close the listening socket once every scripted connection is done, so
    /// a reconnect dial meets ECONNREFUSED rather than an accepting backlog
    close_listener_at_end: bool = false,
};

/// What the server saw, per connection. Read by the test after the server
/// thread joins, so there is no locking.
const ReconnectView = struct {
    generic: ServerView = .{},
    conn_count: usize = 0,
    uploads_per_conn: [8]u32 = [_]u32{0} ** 8,
    /// the guid bytes of every 0x83 upload-begin, per connection, in arrival
    /// order. 0x83 payloads start with the 16-byte guid.
    guids: [8][24][16]u8 = undefined,
    guid_counts: [8]usize = [_]usize{0} ** 8,

    fn recordBegin(self: *ReconnectView, conn_idx: usize, payload: []const u8) void {
        if (conn_idx >= self.uploads_per_conn.len or payload.len < 16) return;
        if (self.guid_counts[conn_idx] >= 24) return;
        const n = self.guid_counts[conn_idx];
        @memcpy(&self.guids[conn_idx][n], payload[0..16]);
        self.guid_counts[conn_idx] += 1;
        self.uploads_per_conn[conn_idx] += 1;
    }
};

fn challengePayloadKeepalive(ka: u8) [16]u8 {
    var out: [16]u8 = undefined;
    @memcpy(out[0..8], "\x01\x23\x45\x67\x89\xAB\xCD\xEF");
    // the session reads keepalive seconds out of caps byte 1
    std.mem.writeInt(u32, out[8..12], @as(u32, ka) << 8, .little);
    std.mem.writeInt(u32, out[12..16], proto.PROTO_VER_CUR, .little);
    return out;
}

fn prepAccepted(cfd: std.posix.socket_t) void {
    // Same two lessons as `scriptedServer`: accept does not inherit
    // O_NONBLOCK, and the first FIN must not park the port in TIME_WAIT
    // mid-suite. The killed connections here close FIRST, though, so linger-0
    // (RST) is deliberately NOT set — the tests want the clean-FIN
    // EndOfStream the incident actually produced.
    var o: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(cfd, std.c.F.GETFL, @as(c_int, 0)))));
    o.NONBLOCK = true;
    _ = std.c.fcntl(cfd, std.c.F.SETFL, @as(c_int, @bitCast(o)));
    if (builtin.os.tag == .macos) {
        std.posix.setsockopt(cfd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, &std.mem.toBytes(@as(c_int, 1))) catch {};
    }
}

fn acceptOne(listener: *Listener) ?std.posix.socket_t {
    const lfd = listener.server.socket.handle;
    var waits: u32 = 0;
    while (true) {
        if (listener.stop.load(.acquire)) return null;
        var fds = [_]std.posix.pollfd{.{ .fd = lfd, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&fds, 1) catch return null;
        if (n == 0) {
            waits += 1;
            if (waits > accept_deadline_waits) return null;
            continue;
        }
        const rc = std.posix.system.accept(lfd, null, null);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR, .AGAIN => continue,
            else => return null,
        }
    }
}

/// Read frames, recording every 0x83 upload-begin, until `want` of them have
/// been seen. Returns false on EOF/error/deadline — a killed-early client.
fn readUploadBegins(cfd: std.posix.socket_t, view: *ReconnectView, conn_idx: usize, want: u32, deadline_ms: u32) bool {
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    var waited: u32 = 0;
    while (waited < deadline_ms) {
        const n = std.posix.read(cfd, buf[len..]) catch |e| switch (e) {
            error.WouldBlock => {
                _ = sleepMs(1);
                waited += 1;
                continue;
            },
            else => return false,
        };
        if (n == 0) return false;
        view.generic.bytes_read += n;
        len += n;
        var off: usize = 0;
        while (len - off >= 5) {
            const t = buf[off];
            const l = std.mem.readInt(u32, buf[off + 1 ..][0..4], .little);
            if (l > net.max_payload or len - off < 5 + l) break;
            if (t == proto.MSG_UPLOAD_INTERVAL_BEGIN) view.recordBegin(conn_idx, buf[off + 5 ..][0..l]);
            off += 5 + @as(usize, l);
            if (view.uploads_per_conn[conn_idx] >= want) return true;
        }
        if (off > 0) {
            std.mem.copyForwards(u8, buf[0 .. len - off], buf[off..len]);
            len -= off;
        }
    }
    return false;
}

/// Drain without ever sending, counting upload-begins as they pass. Returns
/// when the client goes away (clean EOF) or the deadline passes.
/// Drain, counting upload-begins as they pass, and send keepalives every
/// `ka_s` seconds like a real server does — a server that never sends anything
/// after the config is not "healthy", it is the stall-detector's trigger, so
/// every scripted connection that is not deliberately silent must ping. The
/// one deliberate exception is `.silent_ms`, which is what the stall test
/// exists to exercise. Returns when the client goes away (clean EOF) or the
/// deadline passes.
fn drainSilently(cfd: std.posix.socket_t, view: *ReconnectView, conn_idx: usize, deadline_ms: u32, ka_s: u8) void {
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    var waited: u32 = 0;
    // The ping cadence is WALL time, deliberately. A first cut counted
    // WouldBlock iterations, and a victim uploading continuously never yields
    // one — so the "healthy" connection never pinged, the client's stall
    // detector fired on it too, and the test failed exactly the way a machine
    // slower than the author's does. Deadlines that matter are wall-clock.
    const io = harnessIo();
    const started_ms: i64 = clock.nowMs(io);
    var last_ping_ms: i64 = started_ms;
    while (waited < deadline_ms) {
        const now_ms = clock.nowMs(io);
        if (now_ms - started_ms > deadline_ms) return;
        if (ka_s != 0 and now_ms - last_ping_ms >= @as(i64, ka_s) * 1000) {
            if (!sendFrame(cfd, proto.MSG_KEEPALIVE, "")) return;
            last_ping_ms = now_ms;
        }
        const n = std.posix.read(cfd, buf[len..]) catch |e| switch (e) {
            error.WouldBlock => {
                _ = sleepMs(1);
                waited += 1;
                continue;
            },
            else => return,
        };
        if (n == 0) {
            view.generic.saw_eof = true;
            return;
        }
        view.generic.bytes_read += n;
        len += n;
        var off: usize = 0;
        while (len - off >= 5) {
            const t = buf[off];
            const l = std.mem.readInt(u32, buf[off + 1 ..][0..4], .little);
            if (l > net.max_payload or len - off < 5 + l) break;
            if (t == proto.MSG_UPLOAD_INTERVAL_BEGIN) view.recordBegin(conn_idx, buf[off + 5 ..][0..l]);
            off += 5 + @as(usize, l);
        }
        if (off > 0) {
            std.mem.copyForwards(u8, buf[0 .. len - off], buf[off..len]);
            len -= off;
        }
    }
}

fn reconnectServer(listener: *Listener, script: ReconnectScript, view: *ReconnectView) void {
    for (script.conns, 0..) |step, conn_idx| {
        const cfd = acceptOne(listener) orelse return;
        prepAccepted(cfd);
        view.conn_count = conn_idx + 1;

        if (!sendFrame(cfd, proto.MSG_AUTH_CHALLENGE, &challengePayloadKeepalive(script.keepalive_s))) {
            _ = std.posix.errno(std.posix.system.close(cfd));
            return;
        }
        if (!readUntilType(cfd, &view.generic, 0x80, 2000)) {
            _ = std.posix.errno(std.posix.system.close(cfd));
            return;
        }
        if (!sendFrame(cfd, proto.MSG_AUTH_REPLY, &authReplyPayload("kujamba", 8))) {
            _ = std.posix.errno(std.posix.system.close(cfd));
            return;
        }
        if (!readUntilType(cfd, &view.generic, 0x82, 2000)) {
            _ = std.posix.errno(std.posix.system.close(cfd));
            return;
        }
        if (!sendFrame(cfd, proto.MSG_CONFIG_CHANGE_NOTIFY, &configPayload(script.bpm, script.bpi))) {
            _ = std.posix.errno(std.posix.system.close(cfd));
            return;
        }

        switch (step) {
            // An early false from readUploadBegins means the CLIENT hung up
            // first (EOF) — on a slow runner the stall can fire before the
            // first upload-begin crosses. That is not the end of the script:
            // the client is about to dial the next connection, so move on.
            .close_after_uploads => |want| {
                if (!readUploadBegins(cfd, view, conn_idx, want, script.lifetime_ms)) {
                    _ = std.posix.errno(std.posix.system.close(cfd));
                    continue;
                }
                // clean FIN, deliberately: the client must read EndOfStream,
                // the exact symptom the #28 incident logged
                _ = std.posix.errno(std.posix.system.close(cfd));
                if (script.close_listener_at_end and conn_idx + 1 == script.conns.len) listener.close();
            },
            .silent_ms => |ms| {
                if (!readUploadBegins(cfd, view, conn_idx, 1, script.lifetime_ms)) {
                    _ = std.posix.errno(std.posix.system.close(cfd));
                    continue;
                }
                // ka_s = 0: this connection is the deliberate silence
                drainSilently(cfd, view, conn_idx, ms, 0);
                _ = std.posix.errno(std.posix.system.close(cfd));
            },
            .drain => {
                drainSilently(cfd, view, conn_idx, script.lifetime_ms, script.keepalive_s);
                _ = std.posix.errno(std.posix.system.close(cfd));
            },
        }
    }
    if (script.close_listener_at_end) listener.close();
}

const ReconnectRun = struct {
    stats: session.Stats,
    view: ReconnectView,
    elapsed_ns: u64,
};

fn runReconnect(script: ReconnectScript, opts_in: session.Options) !ReconnectRun {
    const alloc = std.testing.allocator;
    const io = harnessIo();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = Listener.init(try std.Io.net.IpAddress.listen(&addr, io, .{}), io);
    defer listener.close();

    var view = ReconnectView{};
    const srv = try std.Thread.spawn(.{}, reconnectServer, .{ &listener, script, &view });
    var opts = opts_in;
    opts.host = "127.0.0.1";
    opts.port = listener.port();
    var s = session.Session.init(alloc, io, opts) catch |e| {
        listener.close();
        srv.join();
        return e;
    };
    defer {
        s.deinit(); // closes the session socket -> the server's read sees EOF
        srv.join();
    }
    s.log.quiet = true;

    const t0 = clock.nowNs(io);
    const stats = s.run() catch s.stats;
    const elapsed = clock.nowNs(io) - t0;
    return .{ .stats = stats, .view = view, .elapsed_ns = @intCast(elapsed) };
}

/// A deterministic loud source: xorshift noise, generated once. Repeat mode
/// reads the first `bar` samples of it every bar, so the encoded bytes are
/// bar-deterministic — and noise encodes to far more than the 2 KiB chunk
/// threshold, which is what puts each bar's 0x83 near the bar's *start* and
/// makes "killed after N upload-begins" mean "killed mid-bar" deterministically.
var reconnect_samples: [48000]f32 = undefined;
var reconnect_samples_ready = false;
var reconnect_fill = SampleSource{ .samples = &reconnect_samples };
fn reconnectSource() session.Source {
    if (!reconnect_samples_ready) {
        var st: u64 = 0x9E3779B97F4A7C15;
        for (&reconnect_samples) |*s| {
            st ^= st << 13;
            st ^= st >> 7;
            st ^= st << 17;
            s.* = @as(f32, @floatFromInt(@as(i64, @intCast(st % 2001)) - 1000)) / 1000.0 * 0.7;
        }
        reconnect_samples_ready = true;
    }
    return reconnect_fill.source();
}

fn reconnectOpts() session.Options {
    return .{
        .srate = 48000,
        .channel_names = &.{"kujamba"},
        .source = reconnectSource(),
        .id_seed = 42,
        .duration_ms = 60_000,
        .reconnect_attempts = 2,
        .reconnect_backoff_start_ms = 10,
        .reconnect_backoff_max_ms = 50,
    };
}

test "reconnect: a killed connection is rejoined and the --intervals cap counts across it (#24)" {
    var opts = reconnectOpts();
    opts.stop_after_intervals = 4;
    const run = try runReconnect(.{ .conns = &.{ .{ .close_after_uploads = 2 }, .drain } }, opts);

    // The cap was reached, not restarted by the reconnect. Where exactly the
    // kill lands inside the bar grid is the machine's business (a slow runner
    // lags generation), so the assertions count only what the reconnect
    // itself determines.
    try std.testing.expect(run.stats.ok);
    try std.testing.expectEqual(@as(u64, 4), run.stats.intervals_uploaded);
    try std.testing.expectEqual(@as(u64, 1), run.stats.reconnects);
    try std.testing.expect(run.stats.outage_ms >= 10);
    // the bar that was mid-flight when the server hung up is one lost bar,
    // with its bytes accounted — not a silent gap in the ledger. Zero is also
    // legal (the kill can land on a boundary); more than one is not: the
    // server hung up exactly once.
    try std.testing.expect(run.stats.intervals_dropped <= 1);
    // Every upload-begin on either connection carries a guid derived from
    // (seed, seq 0..3) — nothing outside the cap's range, i.e. no re-issued
    // or reinvented identity. A fresh guid for the abandoned bar would give
    // one bar two identities and hand the room the start of a phrase it can
    // never hear finish.
    var expected: [4][16]u8 = undefined;
    for (0..4) |i| instrument.deriveGuid(42, i, 0, &expected[i]);
    var seen_on_conn: [4][2]bool = [_][2]bool{ .{ false, false }, .{ false, false }, .{ false, false }, .{ false, false } };
    for (0..2) |conn| {
        var last_seq: i64 = -1;
        for (0..run.view.guid_counts[conn]) |gi| {
            var matched: ?usize = null;
            for (0..4) |i| {
                if (std.mem.eql(u8, &expected[i], &run.view.guids[conn][gi])) matched = i;
            }
            try std.testing.expect(matched != null);
            // per connection, the sequence ascends: one connection sees the
            // bars in order, never backwards
            try std.testing.expect(@as(i64, @intCast(matched.?)) > last_seq);
            last_seq = @intCast(matched.?);
            seen_on_conn[matched.?][conn] = true;
        }
    }
    // and the abandoned bar was RE-SENT: its guid crossed both the killed
    // connection and the resumed one. A resume that skips or replaces it
    // leaves one conn never seeing that guid.
    var resent = false;
    for (0..4) |i| {
        if (seen_on_conn[i][0] and seen_on_conn[i][1]) resent = true;
    }
    try std.testing.expect(resent);
}

test "reconnect: re-sent payloads carry the deterministic serial and decode (#24)" {
    const alloc = std.testing.allocator;
    const dump_dir = "zig-cache/session-timing-out/recon-dump";

    var opts = reconnectOpts();
    opts.stop_after_intervals = 4;
    opts.payload_dump_dir = dump_dir;
    const run = try runReconnect(.{ .conns = &.{ .{ .close_after_uploads = 2 }, .drain } }, opts);
    try std.testing.expect(run.stats.ok);
    try std.testing.expectEqual(@as(u64, 4), run.stats.intervals_uploaded);
    try std.testing.expectEqual(@as(u64, 4), run.stats.payload_dumps);

    // Every dumped interval carries the vorbis serial derived from
    // (seed, seq) — the identity the server keys on, and the one thing a
    // reconnect must not move. The guid is asserted by test 1; the serial
    // lives in the ogg page header at bytes 14-18, so the dumps prove it
    // directly. Byte-for-byte dump comparison across two runs is deliberately
    // NOT asserted: libvorbis packs the packet from the PCM it was handed,
    // and the pass rhythm (hence the final encode block's split point) is the
    // machine's business — measured at one to eight bytes per bar between
    // runs whose only difference is scheduling jitter. See ISSUES.md.
    for (0..4) |i| {
        const path = try std.fmt.allocPrint(alloc, "{s}/interval_{d:0>4}.ogg", .{ dump_dir, i });
        defer alloc.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, alloc, .limited(1 << 20)) catch |e| {
            std.debug.print("missing dump {s}: {s}\n", .{ path, @errorName(e) });
            return error.MissingDump;
        };
        defer alloc.free(bytes);
        try std.testing.expect(bytes.len > 27 + 4);
        const serial = std.mem.readInt(u32, bytes[14..18], .little);
        try std.testing.expectEqual(instrument.deriveSerial(42, i, 0) & 0x7FFFFFFF, serial);
        // and the payload is real, decodable vorbis — not framing debris from
        // the dead connection
        var dec = vorbis.decodeMemory(alloc, bytes) catch |e| {
            std.debug.print("dump {s} does not decode: {s}\n", .{ path, @errorName(e) });
            return error.DecodeFailed;
        };
        defer dec.deinit();
        try std.testing.expect(dec.frames() > 0);
    }
}

test "reconnect: exhausting the dial budget fails the session with the loss reason (#24)" {
    const alloc = std.testing.allocator;
    const transcript_path = "zig-cache/session-timing-out/reconnect-exhausted.log";
    std.Io.Dir.cwd().deleteFile(std.testing.io, transcript_path) catch {};

    var opts = reconnectOpts();
    opts.reconnect_attempts = 2;
    opts.reconnect_backoff_start_ms = 10;
    opts.reconnect_backoff_max_ms = 20;
    opts.transcript_path = transcript_path;
    const run = try runReconnect(
        .{ .conns = &.{.{ .close_after_uploads = 1 }}, .close_listener_at_end = true },
        opts,
    );

    // the budget is a ceiling: the session failed, no rejoin ever landed, and
    // the post-mortem is the loss itself, not the retries
    try std.testing.expect(!run.stats.ok);
    try std.testing.expectEqual(@as(u64, 0), run.stats.reconnects);
    try std.testing.expect(run.stats.outage_ms > 0);
    // the post-mortem is the recorded loss, verbatim. Which read error the
    // killer's close surfaces depends on whether the client was mid-write
    // when the FIN arrived — EndOfStream or ConnectionResetByPeer, whichever
    // the kernel had — so the assertion pins the site, not the errno.
    try std.testing.expect(std.mem.startsWith(u8, run.stats.failText(), "read failed: "));
    // bounded, not "eventually": the retries are priced by the backoff, so a
    // regression to an unbounded retry loop cannot hide behind the deadline
    try std.testing.expect(run.elapsed_ns < 5 * std.time.ns_per_s);
    // exactly `budget` dial attempts were made — an off-by-one in the budget
    // guard shows up here as an extra attempt
    const text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, transcript_path, alloc, .limited(1 << 20)) catch
        return error.TranscriptMissing;
    defer alloc.free(text);
    var attempts: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "reconnect attempt") != null) attempts += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), attempts);
}

test "reconnect: the stall detector rejoins a server that went silent (#24)" {
    const alloc = std.testing.allocator;
    var opts = reconnectOpts();
    opts.stop_after_intervals = 7;
    opts.transcript_path = "zig-cache/session-timing-out/reconnect-stall.log";
    const run = try runReconnect(
        // keepalive 1 s -> the client's stall threshold is 3 s. The server
        // keeps READING while silent, so the client's sends keep landing and
        // the silence is unambiguous: no data *from* the server for 3 s.
        .{ .conns = &.{ .{ .silent_ms = 3500 }, .drain }, .keepalive_s = 1 },
        opts,
    );

    // The cap is what matters: however many bars the slow side managed before
    // the 3 s threshold, the rejoined session finishes the job. Counting bars
    // inside the stall window would measure the runner, not the code (see
    // ISSUES.md: a test that asserts a wall-clock count measures the machine).
    try std.testing.expect(run.stats.ok);
    try std.testing.expectEqual(@as(u64, 7), run.stats.intervals_uploaded);
    try std.testing.expectEqual(@as(u64, 1), run.stats.reconnects);
    // the outage is the dial, not the silence: the client closes the silent
    // connection when the stall fires, and the server's drain returns on the
    // EOF, so the rejoin lands within milliseconds of the threshold
    try std.testing.expect(run.stats.outage_ms > 0);
    // and the trigger really was the stall detector, not a read error
    const stall_text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "zig-cache/session-timing-out/reconnect-stall.log", alloc, .limited(1 << 20)) catch
        return error.TranscriptMissing;
    defer alloc.free(stall_text);
    try std.testing.expect(std.mem.indexOf(u8, stall_text, "CONNECTION LOST: connection stalled") != null);
    try std.testing.expectEqual(@as(usize, 1), blk: {
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, stall_text, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "CONNECTION LOST: connection stalled") != null) n += 1;
        }
        break :blk n;
    });
    // the resumed connection was healthy: no further stalls after the rejoin
    try std.testing.expect(std.mem.indexOf(u8, stall_text, "read failed") == null);
    try std.testing.expectEqual(@as(u32, 4), run.view.uploads_per_conn[0]);
    try std.testing.expectEqual(@as(u32, 4), run.view.uploads_per_conn[1]);
    var g: [16]u8 = undefined;
    for (0..4) |i| {
        instrument.deriveGuid(42, i, 0, &g);
        try std.testing.expectEqualSlices(u8, &g, &run.view.guids[0][i]);
    }
    for (3..7) |i| {
        instrument.deriveGuid(42, i, 0, &g);
        try std.testing.expectEqualSlices(u8, &g, &run.view.guids[1][i - 3]);
    }
}
