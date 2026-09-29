//! Client session state machine: handshake/auth (§4), steady-state dispatch,
//! interval engine (§6.5 uploads, §6.4/§6.2 downloads → WAV), chat (§8),
//! keepalives (§7). Single-threaded: one poll loop drives network + audio.

const std = @import("std");
const bufmod = @import("buf.zig");
const netmod = @import("net.zig");
const proto = @import("proto.zig");
const auth = @import("auth.zig");
const wavmod = @import("wav.zig");
const vorbis = @import("vorbis.zig");
const logmod = @import("log.zig");
const clock = @import("clock.zig");
const audio = @import("audio.zig");

const Fixed = bufmod.Fixed;
const Buf = bufmod.Buf;

pub const Source = union(enum) {
    tone: struct { freq: f32, amp: f32 },
    silence,
};

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 2049,
    user: []const u8 = "anonymous:zclient",
    pass: []const u8 = "",
    srate: u32 = 48000,
    channel_names: []const []const u8 = &.{"zclient"},
    source: Source = .{ .tone = .{ .freq = 440.0, .amp = 0.5 } },
    out_dir: []const u8 = "dump",
    transcript_path: ?[]const u8 = null,
    duration_ms: i64 = 20_000,
    chat: ?[]const u8 = null,
    chat_delay_ms: i64 = 1_500,
    /// libvorbis VBR quality (reference client uses 0.0 for 64 kbps mono)
    quality: f32 = 0.0,

    // ---- Phase B: live audio ----
    /// capture the local device instead of generating --source, and play the
    /// decoded peer mix out of it. Falls back to --source + WAV dumps when no
    /// device can be opened.
    live: bool = false,
    /// device period in frames (0 = backend default)
    live_period: u32 = 480,
    /// optional miniaudio device id (name or index), null = system default
    live_device: ?[]const u8 = null,
    /// optional WAV dump of the exact post-mix signal handed to the device
    play_wav_path: ?[]const u8 = null,
};

pub const Stats = struct {
    ok: bool = false,
    fail_reason: [256]u8 = undefined,
    fail_len: usize = 0,

    msgs_sent: u64 = 0,
    msgs_recv: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_recv: u64 = 0,

    intervals_uploaded: u64 = 0,
    upload_chunks: u64 = 0,
    upload_bytes: u64 = 0,

    intervals_downloaded: u64 = 0,
    download_bytes: u64 = 0,
    samples_decoded: u64 = 0,

    chat_sent: u64 = 0,
    chat_received: u64 = 0,

    wav_count: u32 = 0,
    wav_rms_sum: f64 = 0.0,

    // live audio (Phase B) — energy is measured on the session thread as the
    // samples cross the ring boundary, so a silent device cannot fake it
    live: bool = false,
    device_name: [128]u8 = undefined,
    device_name_len: usize = 0,
    device_srate: u32 = 0,
    capture_frames: u64 = 0,
    capture_zero_frames: u64 = 0,
    capture_peak: f32 = 0,
    capture_energy: f64 = 0,
    playback_frames: u64 = 0,
    playback_peak: f32 = 0,
    playback_energy: f64 = 0,
    rx_underruns: u64 = 0,
    rx_overruns: u64 = 0,

    pub fn deviceName(self: *const Stats) []const u8 {
        return self.device_name[0..self.device_name_len];
    }

    pub fn rms(frames: u64, energy: f64) f64 {
        if (frames == 0) return 0;
        return @sqrt(energy / @as(f64, @floatFromInt(frames)));
    }

    fn fail(self: *Stats, comptime fmt: []const u8, args: anytype) void {
        self.ok = false;
        const s = std.fmt.bufPrint(&self.fail_reason, fmt, args) catch "error";
        self.fail_len = s.len;
    }

    pub fn failText(self: *const Stats) []const u8 {
        return self.fail_reason[0..self.fail_len];
    }
};

const max_users = 32;
const max_downloads = 8;
const max_outputs = 16;
const max_local_channels = 4;

const encode_block_samples = 960; // 20 ms @ 48 kHz
const chunk_flush_bytes = 2048; // coalesce encoded bytes into >=2KiB chunks
const default_keepalive_s: u32 = 3;

const UserEntry = struct {
    name_len: usize = 0,
    name: [160]u8 = undefined,
    mask: u32 = 0, // channels we subscribed to

    fn setName(self: *UserEntry, s: []const u8) void {
        const n = @min(s.len, self.name.len);
        @memcpy(self.name[0..n], s[0..n]);
        self.name_len = n;
    }

    fn nameSlice(self: *const UserEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

const DownloadState = struct {
    active: bool = false,
    guid: [16]u8 = [_]u8{0} ** 16,
    fourcc: u32 = 0,
    chidx: u8 = 0,
    user: UserEntry = .{},
    buf: Buf,
};

const OutputFile = struct {
    active: bool = false,
    chidx: u8 = 0,
    user: UserEntry = .{},
    srate: u32 = 0,
    path_len: usize = 0,
    path: [320]u8 = undefined,
    writer: wavmod.WavWriter,

    fn pathSlice(self: *const OutputFile) []const u8 {
        return self.path[0..self.path_len];
    }
};

const LocalChannel = struct {
    name_len: usize = 0,
    name: [64]u8 = undefined,
    broadcast: bool = true,
    phase: f32 = 0,
    enc: ?*vorbis.Encoder = null,
    guid: [16]u8 = [_]u8{0} ** 16,
    begun: bool = false, // 0x83 sent
    pending: Buf,
    produced: u64 = 0,
    interval_idx: u64 = 0,

    fn nameSlice(self: *const LocalChannel) []const u8 {
        return self.name[0..self.name_len];
    }

    fn setName(self: *LocalChannel, s: []const u8) void {
        const n = @min(s.len, self.name.len);
        @memcpy(self.name[0..n], s[0..n]);
        self.name_len = n;
    }
};

pub const Session = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    stats: Stats = .{},
    log: logmod.Log,

    conn: ?netmod.Conn = null,
    payload: Buf,
    state: enum { connecting, awaiting_reply, active, done } = .connecting,

    keepalive_s: u32 = default_keepalive_s,
    eff_user: UserEntry = .{},
    maxchan: u8 = 1,
    bpm: u16 = 0,
    bpi: u16 = 0,

    users: [max_users]UserEntry = [_]UserEntry{.{}} ** max_users,

    downloads: [max_downloads]DownloadState = undefined,
    outputs: [max_outputs]OutputFile = undefined,

    locals: []LocalChannel = &.{},
    interval_len_samples: u64 = 0,
    interval_start_ns: i128 = 0,
    interval_idx: u64 = 0,

    start_ns: i128 = 0,
    chat_sent: bool = false,
    last_keepalive_ms: i64 = 0,
    hex_scratch: [64]u8 = undefined,
    hex_scratch2: [64]u8 = undefined,

    dev: ?*audio.Device = null,
    play_writer: wavmod.WavWriter = undefined,
    play_wav_active: bool = false,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, opts: Options) !Session {
        var s = Session{
            .alloc = alloc,
            .io = io,
            .opts = opts,
            .log = logmod.Log.init(alloc, io, opts.transcript_path, false),
            .payload = Buf.init(alloc),
        };
        s.start_ns = clock.nowNs(io);
        s.log.start_ns = s.start_ns;
        for (&s.downloads) |*d| d.* = .{ .buf = Buf.init(alloc) };
        for (&s.outputs) |*o| o.* = .{ .writer = wavmod.WavWriter.init(alloc, io, 0, 1) };
        s.locals = try alloc.alloc(LocalChannel, opts.channel_names.len);
        for (s.locals, 0..) |*lc, i| {
            lc.* = .{ .pending = Buf.init(alloc) };
            lc.setName(opts.channel_names[i]);
        }
        return s;
    }

    pub fn deinit(self: *Session) void {
        self.closeWavs();
        self.closeLive();
        for (self.locals) |*lc| {
            if (lc.enc) |e| e.destroy();
            lc.pending.deinit();
        }
        self.alloc.free(self.locals);
        for (&self.downloads) |*d| d.buf.deinit();
        for (&self.outputs) |*o| o.writer.deinit();
        self.payload.deinit();
        if (self.conn) |*c| c.close();
        self.log.deinit();
    }

    fn setNameField(entry: *UserEntry, s: []const u8) void {
        entry.setName(s);
    }

    // ---- helpers -----------------------------------------------------------

    fn failSession(self: *Session, comptime fmt: []const u8, args: anytype) error{SessionFailed} {
        self.stats.fail(fmt, args);
        self.log.line("FAIL: " ++ fmt, args);
        self.state = .done;
        return error.SessionFailed;
    }

    fn findOrAddUser(self: *Session, name: []const u8) ?*UserEntry {
        for (&self.users) |*u| {
            if (u.name_len > 0 and std.mem.eql(u8, u.nameSlice(), name)) return u;
        }
        for (&self.users) |*u| {
            if (u.name_len == 0) {
                UserEntry.setName(u, name);
                return u;
            }
        }
        return null;
    }

    fn hexBuf(src: []const u8, out: []u8) []const u8 {
        const n = @min(out.len / 2, src.len);
        auth.hexLower(src[0..n], out[0 .. n * 2]);
        return out[0 .. n * 2];
    }

    fn sanitizeName(dst: []u8, src: []const u8) usize {
        var n: usize = 0;
        for (src) |ch| {
            if (n >= dst.len) break;
            dst[n] = if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') ch else '_';
            n += 1;
        }
        return n;
    }

    // ---- wav outputs ---------------------------------------------------------

    fn findOrOpenOutput(self: *Session, username: []const u8, chidx: u8, srate: u32) !*OutputFile {
        for (&self.outputs) |*o| {
            if (o.active and o.chidx == chidx and std.mem.eql(u8, o.user.nameSlice(), username)) {
                return o;
            }
        }
        for (&self.outputs) |*o| {
            if (!o.active) {
                o.active = true;
                o.chidx = chidx;
                o.user.setName(username);
                o.srate = srate;
                o.writer = wavmod.WavWriter.init(self.alloc, self.io, srate, 1);
                var tmp: [256]u8 = undefined;
                const nb = sanitizeName(&tmp, username);
                const path = std.fmt.bufPrint(&o.path, "{s}/{s}_ch{d}.wav", .{ self.opts.out_dir, tmp[0..nb], chidx }) catch {
                    o.active = false;
                    return error.OutOfMemory;
                };
                o.path_len = path.len;
                try o.writer.open(o.pathSlice());
                self.log.line("wav open {s} (srate={d})", .{ o.pathSlice(), srate });
                return o;
            }
        }
        return error.NoSlot;
    }

    pub fn closeWavs(self: *Session) void {
        for (&self.outputs) |*o| {
            if (!o.active) continue;
            o.writer.close() catch |e| {
                self.log.line("wav close {s} failed: {s}", .{ o.pathSlice(), @errorName(e) });
            };
            const a = wavmod.analyzeWavFile(self.io, o.pathSlice()) catch {
                self.log.line("wav analyze {s} failed", .{o.pathSlice()});
                continue;
            };
            self.stats.wav_count += 1;
            self.stats.wav_rms_sum += a.rms;
            self.log.line("wav {s} frames={d} srate={d} rms={d:.6} peak={d:.6}", .{ o.pathSlice(), a.frames, a.srate, a.rms, a.peak });
            o.writer.deinit();
            o.active = false;
        }
    }

    // ---- live audio (Phase B) --------------------------------------------------

    fn openLive(self: *Session) void {
        if (!self.opts.live) return;
        if (!audio.enabled) {
            self.log.line("live audio requested but this build has live=false; using --source", .{});
            return;
        }
        var probe: [256]u8 = undefined;
        const p = audio.Device.probePlayback(&probe);
        self.log.line("audio probe: default_playback=\"{s}\" native_srate={d}", .{ p.name, p.srate });

        const id: ?[*:0]const u8 = if (self.opts.live_device) |d| @ptrCast(d) else null;
        self.dev = audio.Device.open(self.alloc, self.opts.srate, self.opts.live_period, id) catch |e| {
            self.log.line("live audio UNAVAILABLE ({s}: {s}); falling back to --source", .{
                @errorName(e), audio.Device.lastError(audio.last_open_error),
            });
            return;
        };
        const d = self.dev.?;
        const n = @min(d.nameSlice().len, self.stats.device_name.len);
        @memcpy(self.stats.device_name[0..n], d.nameSlice()[0..n]);
        self.stats.device_name_len = n;
        self.stats.device_srate = d.dev_srate;
        self.stats.live = true;
        self.log.line("live audio ON: device=\"{s}\" backend={s} srate={d} (session {d}){s}", .{
            d.nameSlice(),                                               d.backend(), d.dev_srate, self.opts.srate,
            if (d.dev_srate == self.opts.srate) "" else " [resampling]",
        });

        if (self.opts.play_wav_path) |path| {
            self.play_writer = wavmod.WavWriter.init(self.alloc, self.io, self.opts.srate, 1);
            self.play_writer.open(path) catch |e| {
                self.log.line("playback wav open '{s}' failed: {s}", .{ path, @errorName(e) });
                return;
            };
            self.play_wav_active = true;
            self.log.line("playback wav open {s}", .{path});
        }
    }

    fn closeLive(self: *Session) void {
        // comptime-gated: with -Dlive=false no device can ever have opened,
        // and this keeps the miniaudio symbols out of the link entirely
        if (!audio.enabled) return;
        if (self.play_wav_active) {
            self.play_writer.close() catch |e| {
                self.log.line("playback wav close failed: {s}", .{@errorName(e)});
            };
            if (self.opts.play_wav_path) |p| {
                if (wavmod.analyzeWavFile(self.io, p)) |a| {
                    self.log.line("playback wav {s} frames={d} srate={d} rms={d:.6} peak={d:.6}", .{
                        p, a.frames, a.srate, a.rms, a.peak,
                    });
                } else |_| {}
            }
            self.play_writer.deinit();
            self.play_wav_active = false;
        }
        if (self.dev) |d| {
            const tx = d.txStats();
            const rx = d.rxStats();
            self.log.line("live audio stats: device_frames={d} queued_tx={d} queued_rx={d}", .{
                d.framesSeen(), d.queuedCapture(), d.queuedPlayback(),
            });
            self.log.line("live audio rings: capture underrun={d} overrun={d} | playback underrun={d} overrun={d}", .{
                tx.under, tx.over, rx.under, rx.over,
            });
            self.stats.rx_underruns = tx.under + rx.under;
            self.stats.rx_overruns = tx.over + rx.over;
            d.deinit(self.alloc);
            self.dev = null;
        }
    }

    /// The device has been capturing since we opened it, but the interval clock
    /// only starts when the server advertises BPM/BPI (a few seconds later).
    /// Uploading that pre-roll would push audio several seconds stale, so drop
    /// it and let the uplink start at the top of interval 0.
    fn dropCapturePreRoll(self: *Session) void {
        const d = self.dev orelse return;
        const dropped = d.flushCapture();
        if (dropped > 0) self.log.line("capture pre-roll dropped: {d} frames", .{dropped});
    }

    /// Take one block of captured audio out of the device ring, filling any
    /// shortfall with silence, and account for it. Runs once per encode step.
    fn pullCapture(self: *Session, d: *audio.Device, block: []f32) void {
        const got = d.readCapture(block);
        for (block[0..got]) |s| {
            const a = @abs(s);
            if (a > self.stats.capture_peak) self.stats.capture_peak = a;
            self.stats.capture_energy += @as(f64, s) * @as(f64, s);
        }
        self.stats.capture_frames += got;
        self.stats.capture_zero_frames += block.len - got;
    }

    /// Hand decoded peer audio to the device (and the optional WAV mirror).
    fn pushPlayback(self: *Session, mono: []const f32) void {
        const d = self.dev orelse return;
        for (mono) |s| {
            const a = @abs(s);
            if (a > self.stats.playback_peak) self.stats.playback_peak = a;
            self.stats.playback_energy += @as(f64, s) * @as(f64, s);
        }
        self.stats.playback_frames += mono.len;
        d.writePlayback(mono);
        if (self.play_wav_active) self.play_writer.writeFloats(mono) catch {};
    }

    // ---- connection ----------------------------------------------------------

    fn send(self: *Session, mtype: u8, payload: []const u8) !void {
        try self.conn.?.sendMessage(mtype, payload);
        self.stats.msgs_sent += 1;
        self.stats.bytes_sent += payload.len + 5;
        self.last_keepalive_ms = clock.nowMs(self.io);
    }

    fn sendChatMsg(self: *Session, parms: []const []const u8) !void {
        var f = Fixed{};
        try proto.buildChat(parms, &f);
        try self.send(proto.MSG_CHAT_MESSAGE, f.slice());
    }

    fn sendKeepaliveIfDue(self: *Session, now_ms: i64) void {
        const idle_ms = now_ms - self.last_keepalive_ms;
        if (idle_ms >= @as(i64, @intCast(self.keepalive_s)) * 1000) {
            self.send(proto.MSG_KEEPALIVE, "") catch {};
            self.log.line("C>S KEEPALIVE (idle {d}ms)", .{idle_ms});
        }
    }

    // ---- upload path (§6.5) ---------------------------------------------------

    fn startIntervalEncoders(self: *Session) !void {
        for (self.locals) |*lc| {
            if (lc.enc) |e| {
                e.destroy();
                lc.enc = null;
            }
            lc.pending.clear();
            lc.begun = false;
            lc.produced = 0;
            self.io.random(&lc.guid);
            var serial: u32 = 0;
            self.io.random(std.mem.asBytes(&serial));
            if (lc.broadcast) {
                lc.enc = vorbis.Encoder.create(self.alloc, @intCast(self.opts.srate), self.opts.quality, serial) catch |e| {
                    return self.failSession("encoder init failed: {s}", .{@errorName(e)});
                };
                // headers go into pending; first send carries 0x83 + them
                var hdrs: std.ArrayList(u8) = .empty;
                defer hdrs.deinit(self.alloc);
                try lc.enc.?.writeHeaders(&hdrs);
                try lc.pending.add(hdrs.items);
            }
        }
    }

    /// Generate + encode audio up to the current wall-clock sample target;
    /// finalize and restart the interval at the boundary.
    fn advanceAudio(self: *Session, now_ns: i128) !void {
        if (self.interval_len_samples == 0) return;
        const elapsed_ns = now_ns - self.interval_start_ns;
        const elapsed_samples: u64 = @intCast(@divFloor(elapsed_ns * @as(i128, self.opts.srate), 1_000_000_000));
        const target = @min(elapsed_samples, self.interval_len_samples);

        while (self.locals[0].produced < target) {
            // all channels advance in lockstep, so every channel encodes the
            // same number of samples per step
            const n0: u64 = @min(encode_block_samples, @min(target - self.locals[0].produced, self.interval_len_samples - self.locals[0].produced));
            const n: usize = @intCast(n0);

            // Live capture is pulled once per step and shared by every channel:
            // one pull per channel would hand each channel a different slice of
            // the device ring and slowly pull them out of time with each other.
            var live_block: [encode_block_samples]f32 = undefined;
            if (self.dev) |d| self.pullCapture(d, live_block[0..n]);

            for (self.locals) |*lc| {
                if (!lc.broadcast) continue;
                var block: [encode_block_samples]f32 = undefined;
                if (self.dev != null) {
                    @memcpy(block[0..n], live_block[0..n]);
                } else switch (self.opts.source) {
                    .tone => |t| {
                        const dphi = 2.0 * std.math.pi * t.freq / @as(f32, @floatFromInt(self.opts.srate));
                        for (block[0..n]) |*s| {
                            lc.phase += dphi;
                            if (lc.phase > 2.0 * std.math.pi) lc.phase -= 2.0 * std.math.pi;
                            s.* = t.amp * @sin(lc.phase);
                        }
                    },
                    .silence => {
                        @memset(block[0..n], 0);
                    },
                }
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(self.alloc);
                lc.enc.?.encode(block[0..n], &out) catch |e| {
                    return self.failSession("encode failed: {s}", .{@errorName(e)});
                };
                try lc.pending.add(out.items);
            }
            for (self.locals) |*lc| {
                lc.produced += n0;
            }
            // stream out full chunks mid-interval
            for (self.locals) |*lc| {
                while (lc.begun and lc.pending.len >= chunk_flush_bytes) {
                    try self.sendUploadChunk(lc, false);
                }
                if (!lc.begun and lc.pending.len >= chunk_flush_bytes) {
                    // first chunk of the interval: send held 0x83 then data
                    try self.sendUploadBegin(lc);
                    try self.sendUploadChunk(lc, false);
                }
            }
        }

        if (self.locals[0].produced >= self.interval_len_samples) {
            try self.finalizeInterval();
        }
    }

    fn sendUploadBegin(self: *Session, lc: *LocalChannel) !void {
        var f = Fixed{};
        try proto.buildUploadIntervalBegin(.{
            .guid = lc.guid,
            .estsize = 0,
            .fourcc = proto.FOURCC_OGGV,
            .chidx = @intCast(self.channelIndex(lc)),
        }, &f);
        try self.send(proto.MSG_UPLOAD_INTERVAL_BEGIN, f.slice());
        lc.begun = true;
        self.log.line("C>S 0x83 UPLOAD_BEGIN guid={s} chidx={d} interval={d}", .{
            hexBuf(&lc.guid, &self.hex_scratch), self.channelIndex(lc), self.interval_idx,
        });
    }

    fn channelIndex(self: *Session, lc: *LocalChannel) usize {
        return (@intFromPtr(lc) - @intFromPtr(self.locals.ptr)) / @sizeOf(LocalChannel);
    }

    fn sendUploadChunk(self: *Session, lc: *LocalChannel, final: bool) !void {
        // payload cap: 16384 - 17 = 16367 bytes per write message
        const cap: usize = 16367;
        var remaining = lc.pending.items();
        if (remaining.len == 0) {
            if (!final) return;
            // must terminate the transfer even with no data: empty write
            var f0 = Fixed{};
            try proto.buildUploadIntervalWrite(.{ .guid = lc.guid, .flags = 1, .data = "" }, &f0);
            try self.send(proto.MSG_UPLOAD_INTERVAL_WRITE, f0.slice());
            self.stats.upload_chunks += 1;
            self.log.line("C>S 0x84 WRITE guid={s} flags=1 bytes=0 (final)", .{hexBuf(&lc.guid, &self.hex_scratch)});
            return;
        }
        while (remaining.len > 0) {
            const n = @min(remaining.len, cap);
            const is_last = (n == remaining.len);
            var f = Fixed{};
            try proto.buildUploadIntervalWrite(.{
                .guid = lc.guid,
                .flags = if (final and is_last) 1 else 0,
                .data = remaining[0..n],
            }, &f);
            try self.send(proto.MSG_UPLOAD_INTERVAL_WRITE, f.slice());
            self.stats.upload_chunks += 1;
            self.stats.upload_bytes += n;
            self.log.line("C>S 0x84 WRITE guid={s} flags={d} bytes={d}", .{
                hexBuf(&lc.guid, &self.hex_scratch), @as(u8, if (final and is_last) 1 else 0), n,
            });
            remaining = remaining[n..];
        }
        lc.pending.clear();
    }

    fn finalizeInterval(self: *Session) !void {
        for (self.locals) |*lc| {
            if (lc.broadcast) {
                if (lc.enc) |e| {
                    var out: std.ArrayList(u8) = .empty;
                    defer out.deinit(self.alloc);
                    e.flush(&out) catch |err| {
                        return self.failSession("encode flush failed: {s}", .{@errorName(err)});
                    };
                    try lc.pending.add(out.items);
                }
                if (!lc.begun) {
                    if (lc.pending.len == 0) {
                        // nothing encoded at all this interval: silence marker
                        var f = Fixed{};
                        try proto.buildUploadIntervalBegin(.{
                            .guid = [_]u8{0} ** 16,
                            .estsize = 0,
                            .fourcc = 0,
                            .chidx = @intCast(self.channelIndex(lc)),
                        }, &f);
                        try self.send(proto.MSG_UPLOAD_INTERVAL_BEGIN, f.slice());
                        self.log.line("C>S 0x83 SILENCE_MARKER chidx={d}", .{self.channelIndex(lc)});
                    } else {
                        try self.sendUploadBegin(lc);
                    }
                }
                try self.sendUploadChunk(lc, true);
            } else {
                // channel not broadcasting: periodic silence marker (§6.5.4)
                var f = Fixed{};
                try proto.buildUploadIntervalBegin(.{
                    .guid = [_]u8{0} ** 16,
                    .estsize = 0,
                    .fourcc = 0,
                    .chidx = @intCast(self.channelIndex(lc)),
                }, &f);
                try self.send(proto.MSG_UPLOAD_INTERVAL_BEGIN, f.slice());
                self.log.line("C>S 0x83 SILENCE_MARKER chidx={d}", .{self.channelIndex(lc)});
            }
        }
        self.stats.intervals_uploaded += 1;
        self.log.line("interval {d} complete ({d} samples, {d}ms)", .{
            self.interval_idx, self.interval_len_samples, self.interval_len_samples * 1000 / self.opts.srate,
        });
        self.interval_idx += 1;
        // re-anchor on the exact grid to avoid drift
        const interval_ns: i128 = @divTrunc(@as(i128, @intCast(self.interval_len_samples)) * 1_000_000_000, @as(i128, self.opts.srate));
        self.interval_start_ns += interval_ns;
        self.startIntervalEncoders() catch |e| return e;
    }

    // ---- download path (§6.2/§6.4) ----------------------------------------------

    fn findDownload(self: *Session, guid: *const [16]u8) ?*DownloadState {
        for (&self.downloads) |*d| {
            if (d.active and std.mem.eql(u8, &d.guid, guid)) return d;
        }
        return null;
    }

    fn allocDownload(self: *Session, guid: *const [16]u8, fourcc: u32, chidx: u8, username: []const u8) ?*DownloadState {
        for (&self.downloads) |*d| {
            if (!d.active) {
                d.active = true;
                d.guid = guid.*;
                d.fourcc = fourcc;
                d.chidx = chidx;
                d.user.setName(username);
                d.buf.clear();
                return d;
            }
        }
        return null;
    }

    fn finalizeDownload(self: *Session, d: *DownloadState) !void {
        self.stats.intervals_downloaded += 1;
        self.log.line("download complete user={s} ch={d} bytes={d} fourcc=0x{X:0>8}", .{
            d.user.nameSlice(), d.chidx, d.buf.len, d.fourcc,
        });
        if (d.fourcc != proto.FOURCC_OGGV) {
            self.log.line("skip decode: unknown fourcc", .{});
            d.active = false;
            d.buf.clear();
            return;
        }
        var dec = vorbis.decodeMemory(self.alloc, d.buf.items()) catch |e| {
            self.log.line("DECODE FAILED user={s}: {s}", .{ d.user.nameSlice(), @errorName(e) });
            d.active = false;
            d.buf.clear();
            return;
        };
        defer dec.deinit();
        self.stats.samples_decoded += dec.frames();
        self.log.line("decoded user={s} ch={d} srate={d} ch={d} frames={d} rms={d:.6}", .{
            d.user.nameSlice(), d.chidx, dec.srate, dec.channels, dec.frames(), dec.rms(),
        });
        // downmix to mono for the dump
        if (dec.channels >= 1) {
            const mono = try self.alloc.alloc(f32, dec.frames());
            defer self.alloc.free(mono);
            for (0..dec.frames()) |i| {
                var s: f32 = 0;
                for (0..dec.channels) |k| s += dec.pcm[i * dec.channels + k];
                mono[i] = s / @as(f32, @floatFromInt(dec.channels));
            }
            const out = self.findOrOpenOutput(d.user.nameSlice(), d.chidx, dec.srate) catch |e| {
                self.log.line("wav open failed: {s}", .{@errorName(e)});
                d.active = false;
                d.buf.clear();
                return;
            };
            try out.writer.writeFloats(mono);
            self.pushPlayback(mono);
        }
        d.active = false;
        d.buf.clear();
    }

    // ---- message dispatch ---------------------------------------------------------

    fn dispatch(self: *Session, msg: netmod.Message) !void {
        self.stats.msgs_recv += 1;
        self.stats.bytes_recv += msg.payload.len + 5;
        switch (msg.mtype) {
            proto.MSG_AUTH_CHALLENGE => try self.onChallenge(msg.payload),
            proto.MSG_AUTH_REPLY => try self.onAuthReply(msg.payload),
            proto.MSG_CONFIG_CHANGE_NOTIFY => try self.onConfig(msg.payload),
            proto.MSG_USERINFO_CHANGE_NOTIFY => try self.onUserinfo(msg.payload),
            proto.MSG_DOWNLOAD_INTERVAL_BEGIN => try self.onDownloadBegin(msg.payload),
            proto.MSG_DOWNLOAD_INTERVAL_WRITE => try self.onDownloadWrite(msg.payload),
            proto.MSG_CHAT_MESSAGE => try self.onChat(msg.payload),
            proto.MSG_KEEPALIVE => {},
            else => {
                self.log.line("S>C 0x{X:0>2} UNKNOWN size={d} (ignored)", .{ msg.mtype, msg.payload.len });
            },
        }
    }

    fn onChallenge(self: *Session, payload: []const u8) !void {
        const ch = proto.parseChallenge(payload) catch {
            return self.failSession("bad auth challenge (size={d})", .{payload.len});
        };
        if (ch.protocol_version < proto.PROTO_VER_MIN or ch.protocol_version >= proto.PROTO_VER_MAX) {
            return self.failSession("server protocol 0x{X:0>8} out of range", .{ch.protocol_version});
        }
        const ka: u32 = (ch.server_caps >> 8) & 0xff;
        self.keepalive_s = if (ka == 0) default_keepalive_s else ka;
        self.log.line("S>C 0x00 CHALLENGE challenge={s} caps=0x{X:0>8} ver=0x{X:0>8} keepalive={d}s license={d}b", .{
            hexBuf(&ch.challenge, &self.hex_scratch), ch.server_caps, ch.protocol_version, self.keepalive_s, ch.license.len,
        });
        if (ch.server_caps & 1 != 0) {
            self.log.line("license text (auto-accepted): {d} bytes", .{ch.license.len});
        }

        var reply: [20]u8 = undefined;
        auth.passwordReply(self.opts.user, self.opts.pass, &ch.challenge, &reply);
        var caps: u32 = 0;
        if (ch.server_caps & 1 != 0) caps |= 1; // agree to license
        var f = Fixed{};
        try proto.buildAuthUser(.{
            .passhash = reply,
            .username = self.opts.user,
            .client_caps = caps,
            .client_version = proto.PROTO_VER_CUR,
        }, &f);
        self.log.line("C>S 0x80 AUTH_USER user={s} hash={s} caps={d}", .{ self.opts.user, hexBuf(&reply, &self.hex_scratch2), caps });
        try self.send(proto.MSG_AUTH_USER, f.slice());
        self.state = .awaiting_reply;
    }

    fn onAuthReply(self: *Session, payload: []const u8) !void {
        const rep = proto.parseAuthReply(payload) catch {
            return self.failSession("bad auth reply", .{});
        };
        if (!rep.flag_success) {
            return self.failSession("auth failed: {s}", .{rep.text});
        }
        self.eff_user.setName(rep.text);
        self.maxchan = rep.maxchan orelse 1;
        self.log.line("S>C 0x01 AUTH_OK user={s} maxchan={d}", .{ self.eff_user.nameSlice(), self.maxchan });
        self.state = .active;

        // announce local channels (§4.8 step: client sends 0x82 right after auth)
        var chans: [max_local_channels]proto.ChannelInfoRecord = undefined;
        const n = @min(self.locals.len, max_local_channels);
        for (0..n) |i| chans[i] = .{ .name = self.locals[i].nameSlice() };
        var f = Fixed{};
        try proto.buildChannelInfo(chans[0..n], &f);
        self.log.line("C>S 0x82 SET_CHANNEL_INFO n={d}", .{n});
        try self.send(proto.MSG_SET_CHANNEL_INFO, f.slice());
    }

    fn onConfig(self: *Session, payload: []const u8) !void {
        const cfg = proto.parseConfig(payload) catch {
            return self.failSession("bad config change", .{});
        };
        const changed = cfg.bpm != self.bpm or cfg.bpi != self.bpi;
        self.bpm = cfg.bpm;
        self.bpi = cfg.bpi;
        self.log.line("S>C 0x02 CONFIG bpm={d} bpi={d}", .{ cfg.bpm, cfg.bpi });

        if (changed) {
            // finalize any in-flight interval cleanly, then adopt new timing
            if (self.interval_len_samples != 0 and self.locals[0].produced > 0) {
                try self.finalizeInterval();
            }
            self.interval_len_samples = @intCast(@divTrunc(@as(u64, self.opts.srate) * @as(u64, cfg.bpi) * 60, @as(u64, cfg.bpm)));
            self.interval_start_ns = clock.nowNs(self.io);
            self.interval_idx = 0;
            self.dropCapturePreRoll();
            try self.startIntervalEncoders();
            self.log.line("interval clock started: {d} samples ({d}ms)", .{
                self.interval_len_samples, self.interval_len_samples * 1000 / self.opts.srate,
            });
        }
    }

    fn onUserinfo(self: *Session, payload: []const u8) !void {
        var sink = proto.UserInfoSink{};
        proto.parseUserinfoRecords(payload, &sink) catch {
            return self.failSession("bad userinfo change", .{});
        };
        self.log.line("S>C 0x03 USERINFO nrecords={d}", .{sink.count});
        for (sink.items()) |rec| {
            self.log.line("  user={s} ch={d} active={d} name={s} flags=0x{X:0>2}", .{
                rec.username, rec.channel_id, @intFromBool(rec.active), rec.channel_name, rec.flags,
            });
            if (!rec.active) continue;
            const u = self.findOrAddUser(rec.username) orelse continue;
            const bit = @as(u32, 1) << @intCast(rec.channel_id);
            if (u.mask & bit == 0) {
                u.mask |= bit;
                // auto-subscribe like the reference client (§5.8, njclient.cpp:1184)
                var f = Fixed{};
                try proto.buildUsermaskRecord(.{ .username = u.nameSlice(), .channelmask = u.mask }, &f);
                self.log.line("C>S 0x81 SET_USERMASK user={s} mask=0x{X:0>8}", .{ u.nameSlice(), u.mask });
                try self.send(proto.MSG_SET_USERMASK, f.slice());
            }
        }
    }

    fn onDownloadBegin(self: *Session, payload: []const u8) !void {
        const b = proto.parseIntervalBegin(payload) catch {
            return self.failSession("bad download begin", .{});
        };
        if (proto.isZeroGuid(&b.guid) and b.fourcc == 0) {
            self.log.line("S>C 0x04 SILENCE_MARKER user={s} ch={d}", .{ b.username, b.chidx });
            return;
        }
        if (self.allocDownload(&b.guid, b.fourcc, b.chidx, b.username)) |_| {
            self.log.line("S>C 0x04 DOWNLOAD_BEGIN user={s} ch={d} guid={s} fourcc=0x{X:0>8}", .{
                b.username, b.chidx, hexBuf(&b.guid, &self.hex_scratch), b.fourcc,
            });
        } else {
            self.log.line("download table full, dropping transfer from {s}", .{b.username});
        }
    }

    fn onDownloadWrite(self: *Session, payload: []const u8) !void {
        const w = proto.parseIntervalWrite(payload) catch {
            return self.failSession("bad download write", .{});
        };
        const d = self.findDownload(&w.guid) orelse {
            self.log.line("S>C 0x05 WRITE for unknown guid (ignored)", .{});
            return;
        };
        try d.buf.add(w.data);
        self.stats.download_bytes += w.data.len;
        self.log.line("S>C 0x05 WRITE user={s} bytes={d} flags={d} total={d}", .{
            d.user.nameSlice(), w.data.len, w.flags, d.buf.len,
        });
        if (w.flags & 1 != 0) {
            try self.finalizeDownload(d);
        }
    }

    fn onChat(self: *Session, payload: []const u8) !void {
        const p = proto.parseChat(payload) catch {
            return self.failSession("bad chat message", .{});
        };
        self.stats.chat_received += 1;
        self.log.line("S>C 0xC0 CHAT {s}: {s} | {s} | {s} | {s}", .{
            p.get(0), p.get(1), p.get(2), p.get(3), p.get(4),
        });
    }

    // ---- main loop -------------------------------------------------------------------

    pub fn run(self: *Session) !Stats {
        std.Io.Dir.cwd().createDirPath(self.io, self.opts.out_dir) catch {};

        self.openLive();

        var hostbuf: [256]u8 = undefined;
        const hostport = std.fmt.bufPrint(&hostbuf, "{s}:{d}", .{ self.opts.host, self.opts.port }) catch "host";
        self.log.line("connecting to {s} as {s}", .{ hostport, self.opts.user });
        self.conn = netmod.Conn.connect(self.io, self.opts.host, self.opts.port) catch |e| {
            return self.failSession("connect failed: {s}", .{@errorName(e)});
        };
        self.log.line("connected", .{});
        self.last_keepalive_ms = clock.nowMs(self.io);

        const deadline_ns = self.start_ns + @as(i128, self.opts.duration_ms) * 1_000_000;

        while (self.state != .done) {
            const now_ns = clock.nowNs(self.io);
            if (now_ns >= deadline_ns) {
                self.stats.ok = true;
                self.state = .done;
                break;
            }

            // drain any readable messages
            var readable = true;
            while (readable and self.state != .done) {
                readable = self.conn.?.pollReadable(0) catch |e| {
                    return self.failSession("poll failed: {s}", .{@errorName(e)});
                };
                if (!readable) break;
                const msg = self.conn.?.readMessage(&self.payload) catch |e| switch (e) {
                    error.WouldBlock => break,
                    else => return self.failSession("read failed: {s}", .{@errorName(e)}),
                };
                try self.dispatch(msg);
            }
            if (self.state != .done) {
                // wait up to 20 ms for the next message
                _ = self.conn.?.pollReadable(20) catch {};
            }

            if (self.state == .active) {
                const now2 = clock.nowNs(self.io);
                self.advanceAudio(now2) catch |e| switch (e) {
                    error.SessionFailed => {},
                    else => return self.failSession("audio advance failed: {s}", .{@errorName(e)}),
                };
                if (self.state == .done) break;

                if (self.opts.chat != null and !self.chat_sent and
                    now2 - self.start_ns >= @as(i128, self.opts.chat_delay_ms) * 1_000_000)
                {
                    self.sendChatMsg(&[_][]const u8{ "MSG", self.opts.chat.? }) catch |e| {
                        return self.failSession("chat send failed: {s}", .{@errorName(e)});
                    };
                    self.chat_sent = true;
                    self.stats.chat_sent += 1;
                    self.log.line("C>S 0xC0 CHAT MSG: {s}", .{self.opts.chat.?});
                }
            }

            const now_ms = clock.nowMs(self.io);
            if (now_ms - self.conn.?.last_recv_ms > @as(i64, @intCast(self.keepalive_s)) * 3000) {
                return self.failSession("connection stalled: no data for {d}ms", .{now_ms - self.conn.?.last_recv_ms});
            }
            if (self.state == .active) self.sendKeepaliveIfDue(now_ms);
        }

        self.closeWavs();
        self.closeLive();
        self.log.line("session end: ok={}", .{self.stats.ok});
        return self.stats;
    }
};
