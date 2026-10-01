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
const instrument = @import("instrument.zig");

const Fixed = bufmod.Fixed;
const Buf = bufmod.Buf;

pub const Source = union(enum) {
    tone: struct { freq: f32, amp: f32 },
    silence,
    /// Borrowed source callback, called per channel on the session thread.
    /// It must fill the whole block and may advance its own playhead, including
    /// when upload backpressure causes the session to discard that audio.
    custom: CustomSource,
};

pub const CustomSource = struct {
    ctx: *anyopaque,
    fill: *const fn (ctx: *anyopaque, offset: u64, samples: []f32) void,
};

/// Called once at each bar boundary, before generating any audio, including
/// rest bars. The owner may apply a pending source selection here and returns
/// whether the bar broadcasts audio or sends a silence marker. All callback
/// contexts must outlive Session.run(); no callback owns application policy.
pub const IntervalPlan = struct {
    ctx: *anyopaque,
    selectFor: *const fn (ctx: *anyopaque, grid: u64) bool,
};

/// Borrowed parsed chat fields, valid only during this synchronous callback.
pub const ChatHook = struct {
    ctx: *anyopaque,
    receive: *const fn (ctx: *anyopaque, message: proto.ChatParms) void,
};

pub const StopHook = struct {
    ctx: ?*anyopaque = null,
    requested: *const fn (ctx: ?*anyopaque) bool,
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

    // ---- instrument additions (kujamba adaptation) ----
    /// deterministic id seed: guid + vorbis serial derive from (seed, interval)
    id_seed: ?u64 = null,
    /// per-interval broadcast plan; false = silence-marker bar (rest bar)
    plan: ?IntervalPlan = null,
    /// null preserves the conformance client's log-only chat behavior.
    on_chat: ?ChatHook = null,
    /// Finalize the generated portion of the current bar and stop; also
    /// interrupts reconnect waits without generating more audio.
    stop: ?StopHook = null,
    /// when set, each interval's concatenated 0x84 payload is dumped to
    /// <dir>/interval_NNNN.ogg (byte-identical across runs for a fixed seed)
    payload_dump_dir: ?[]const u8 = null,
    /// stop after this many completed intervals (demo determinism aid)
    stop_after_intervals: ?u64 = null,

    // ---- reconnect (#24) ----
    /// how many times a lost connection may be re-dialled before the session
    /// gives up. 0 (the default) keeps the old behaviour: a connection-level
    /// death ends the session. The instrument turns this on via `--reconnect`.
    reconnect_attempts: u32 = 0,
    /// first reconnect delay in ms; doubles per attempt up to the max below
    reconnect_backoff_start_ms: i64 = 500,
    /// ceiling on one reconnect delay in ms
    reconnect_backoff_max_ms: i64 = 8_000,

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
    /// local channels that actually streamed audio (max across intervals)
    upload_channels: u64 = 0,
    /// intervals that broadcast real audio (rest bars excluded)
    intervals_broadcast: u64 = 0,
    /// silence markers sent (rest bars / non-broadcast intervals)
    silence_markers: u64 = 0,
    /// interval payload dumps written (payload_dump_dir)
    payload_dumps: u64 = 0,

    // ---- M5 timing telemetry (#13, #14) ------------------------------------
    /// Wall time spent inside one interval's upload-write section, in ns. The
    /// audio clock's own budget is one interval; a value near or above it means
    /// the network stalled interval generation rather than the other way round.
    /// Max over the session, because the worst stall is the one that matters.
    upload_stall_ns: u64 = 0,
    /// #13: signed nanoseconds between the local interval grid and the grid
    /// derived from the server's 0x02 arrival. Positive = the local clock is
    /// running ahead of the server's. Reported (abs) at the end of the session.
    drift_ns: i64 = 0,
    /// #13: absolute value of the largest |drift| seen, in ns.
    max_abs_drift_ns: u64 = 0,
    /// #13: how many intervals the bounded slew actually moved, and the total
    /// correction applied (ns). A session where these are zero is one where the
    /// local grid already agreed with the server's.
    clock_corrections: u64 = 0,
    total_correction_ns: i64 = 0,
    /// #14: bars whose upload was abandoned because the socket would block,
    /// and the encoded bytes thrown away with them.
    intervals_dropped: u64 = 0,
    upload_bytes_dropped: u64 = 0,
    /// kujamba (#14): subset of intervals_dropped caused by write backpressure,
    /// not a reconnect. Conscious vendored Stats divergence for #29.
    intervals_backpressured: u64 = 0,

    /// #24: successful rejoins after a connection-level loss. An attempt that
    /// never lands does not count — it is priced into `outage_ms` instead.
    reconnects: u64 = 0,
    /// #24: total time spent disconnected across every outage in the session,
    /// in ms — backoff sleeps, refused dials and handshake time included. This
    /// is the number the `RESULT` line reports as the cost of the incident.
    outage_ms: u64 = 0,

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

    /// #24: the loss reason is provisional — it describes the connection that
    /// died, and a successful rejoin means the session survived it. Cleared on
    /// reconnect so a session that ends well does not report a stale error.
    pub fn clearFail(self: *Stats) void {
        self.fail_len = 0;
    }
};

const max_users = 32;
const max_downloads = 8;
const max_outputs = 16;
const max_local_channels = 4;

const encode_block_samples = 960; // 20 ms @ 48 kHz
const chunk_flush_bytes = 2048; // coalesce encoded bytes into >=2KiB chunks
const default_keepalive_s: u32 = 3;
/// kujamba (#14): how long an upload write may wait for a slow socket, in ms.
///
/// Zero, and that is the point. The audio clock has exactly one bar of budget
/// and the upload is not worth any of it: a socket that cannot take a bar right
/// now will not take it a second later either, and finding that out by waiting
/// is what turned a jittery connection into a frozen performance. Zero means
/// ask once and act on the answer.
pub const upload_write_budget_ms: i32 = 0;

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
    /// per-interval concatenated 0x84 payload (payload_dump_dir evidence)
    dump: Buf,
    produced: u64 = 0,
    /// kujamba (#14): this channel's bar was abandoned because the socket would
    /// block. Nothing more is sent for it this bar, and the audio keeps going.
    dropped: bool = false,

    fn nameSlice(self: *const LocalChannel) []const u8 {
        return self.name[0..self.name_len];
    }

    fn setName(self: *LocalChannel, s: []const u8) void {
        const n = @min(s.len, self.name.len);
        @memcpy(self.name[0..n], s[0..n]);
        self.name_len = n;
    }
};

/// Fill `block[0..n]` with the audio one local channel should encode for the
/// current step.
///
/// In live mode `shared` is the single capture block taken for this step and
/// every channel encodes a copy of it — that is what keeps multiple channels
/// sample-aligned with each other. Pulling per channel instead would hand each
/// channel a different slice of the device ring and slowly drift them apart.
/// Synthetic sources generate per channel, so each keeps its own phase.
pub fn encodeBlockFor(
    source: Source,
    srate: u32,
    lc: *LocalChannel,
    shared: ?[]const f32,
    block: []f32,
) void {
    if (shared) |s| {
        const n = @min(block.len, s.len);
        @memcpy(block[0..n], s[0..n]);
        return;
    }
    switch (source) {
        .tone => |t| {
            const dphi = 2.0 * std.math.pi * t.freq / @as(f32, @floatFromInt(srate));
            for (block) |*s| {
                lc.phase += dphi;
                if (lc.phase > 2.0 * std.math.pi) lc.phase -= 2.0 * std.math.pi;
                s.* = t.amp * @sin(lc.phase);
            }
        },
        .silence => {
            @memset(block, 0);
        },
        .custom => |source_fn| {
            source_fn.fill(source_fn.ctx, lc.produced, block);
        },
    }
}

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
    // kujamba adaptation (#12): the old single `interval_idx` conflated
    // interval identity with grid position, so a mid-session 0x02 config
    // change re-issued guids already sent (different payload bytes) and
    // overwrote earlier payload dumps. `index.seq` is identity (guids,
    // dump filenames, --intervals) and is monotonic for the whole session;
    // `index.grid` is the bar position and drives only the pattern decision.
    index: instrument.IntervalIndex = .{},
    // kujamba (#13): the bar grid, anchored to the server's and corrected by a
    // bounded slew. See `instrument.ServerClock` for why the correction chases
    // the wall clock rather than the server's epoch.
    timing: instrument.ServerClock = .{},
    // kujamba (#14): has *this* bar already been counted as dropped? Cleared at
    // the start of each interval, so N channels failing on one bar is one
    // lost bar, not N.
    drop_marked: bool = false,
    // kujamba (#24): when the current outage began, if the session is
    // disconnected. Null means connected (or never connected). This is what
    // distinguishes the first dial from a reconnect dial in the run loop, and
    // what `outage_ms` is accumulated from when the connection comes back.
    conn_lost_ns: ?i128 = null,

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
            lc.* = .{ .pending = Buf.init(alloc), .dump = Buf.init(alloc) };
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
            lc.dump.deinit();
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

    /// #24: end the session with the reason already sitting in `stats` (the
    /// provisional loss reason `markConnectionLost` recorded). Re-running
    /// `stats.fail` on `failText()` would print a slice out of the very buffer
    /// it is printing into, which `@memcpy` rightly refuses to alias.
    fn failSessionWithRecordedReason(self: *Session) error{SessionFailed} {
        // the outage the retries priced in is still open — close it, so the
        // post-mortem reports the disconnection the session actually suffered
        if (self.conn_lost_ns) |t0| {
            self.stats.outage_ms += @intCast(@divTrunc(clock.nowNs(self.io) - t0, 1_000_000));
            self.conn_lost_ns = null;
        }
        self.log.line("FAIL: {s}", .{self.stats.failText()});
        self.state = .done;
        return error.SessionFailed;
    }

    /// #24: the connection just died. Record the loss, close the socket, start
    /// the outage clock. Everything bound to the dead connection — the
    /// in-flight bar, peer state, the learned config — is left in place until
    /// the run loop decides what happens next: a reconnect tears it down in
    /// `resetForReconnect`, and a session that gives up keeps it as the
    /// post-mortem.
    ///
    /// The failure reason is provisional: if a rejoin lands, `clearFail` wipes
    /// it, because the session survived what it describes.
    fn markConnectionLost(self: *Session, comptime fmt: []const u8, args: anytype) void {
        self.stats.fail(fmt, args);
        self.log.line("CONNECTION LOST: " ++ fmt, args);
        if (self.conn) |*c| c.close();
        self.conn = null;
        self.conn_lost_ns = clock.nowNs(self.io);
        self.state = .connecting;
    }

    /// #24: return the session to its post-auth, pre-config shape so the fresh
    /// handshake's `0x02` re-anchors everything.
    ///
    /// The load-bearing subtlety is `bpm = 0`. The re-anchor path in `onConfig`
    /// only runs when the new config *differs*, and a reconnect to the same
    /// server almost always hands back the same bpm/bpi. Zeroing the learned
    /// config forces that path to fire — it is the one place that re-anchors
    /// the clock and restarts the interval engine — and it is semantically
    /// honest: a fresh server session knows nothing about the old one, so the
    /// session returns to "not yet configured" until told otherwise.
    ///
    /// What is deliberately NOT reset:
    ///  - `index.seq`: identity is monotonic for the whole run, so a resumed
    ///    session never re-issues a guid (which is also what keeps the
    ///    `--intervals` cap counting across reconnects instead of restarting).
    ///  - the phrase cursor: the room lost contact, not the instrument; the
    ///    next bar picks up where the abandoned one was generated.
    ///  - `timing`'s drift ledger: `onConfig`'s re-anchor keeps it continuous.
    ///
    /// The in-flight bar, if there was one, is abandoned the #14 way — counted
    /// once as dropped, its bytes counted, nothing of it sent again. The grid
    /// genuinely restarts (`reanchor(0)` is the escape hatch #12 built for
    /// this), so the pattern starts from its top at the next bar.
    fn resetForReconnect(self: *Session) void {
        var abandoned_bytes: u64 = 0;
        var abandoned = false;
        for (self.locals) |*lc| {
            abandoned_bytes += lc.pending.len + lc.dump.len;
            if (lc.produced > 0 or lc.pending.len > 0 or lc.dump.len > 0 or lc.begun) abandoned = true;
            if (lc.enc) |e| {
                e.destroy();
                lc.enc = null;
            }
            lc.pending.clear();
            lc.dump.clear();
            lc.begun = false;
            lc.produced = 0;
            lc.dropped = false;
            lc.broadcast = true;
        }
        if (abandoned) {
            // one lost bar, not N — same accounting rule as a socket-drop
            if (!self.drop_marked) self.stats.intervals_dropped += 1;
            self.stats.upload_bytes_dropped += abandoned_bytes;
            self.log.line("reconnect: bar {d} abandoned mid-flight ({d} bytes discarded) — resuming at the next bar", .{
                self.index.seq, abandoned_bytes,
            });
        }
        // peers, downloads and their WAV outputs belonged to the dead connection
        self.closeWavs();
        for (&self.downloads) |*d| {
            d.active = false;
            d.buf.clear();
        }
        for (&self.users) |*u| {
            u.name_len = 0;
            u.mask = 0;
        }
        self.eff_user = .{};
        self.maxchan = 1;
        self.bpm = 0;
        self.bpi = 0;
        self.interval_len_samples = 0;
        self.keepalive_s = default_keepalive_s;
        self.chat_sent = false;
        self.drop_marked = false;
        self.index.reanchor(0);
    }

    /// #24: sleep for reconnect backoff, interruptibly. The session is
    /// single-threaded, so the wait is sliced and each slice re-checks the two
    /// things that outrank a retry: a stop request and the session deadline.
    /// Returns false when the wait was cut short — the caller ends the session
    /// gracefully rather than dialling into a performance that is already over.
    fn sleepInterruptibly(self: *Session, ms: i64, deadline_ns: i128) enum { proceeded, stopped, expired } {
        const wake_ns = clock.nowNs(self.io) + @as(i128, ms) * std.time.ns_per_ms;
        while (true) {
            const now = clock.nowNs(self.io);
            if (now >= wake_ns) return .proceeded;
            if (now >= deadline_ns) return .expired;
            if (self.stopRequested()) return .stopped;
            // slice the wait into ≤25 ms sleeps so a stop request and the
            // deadline are noticed promptly rather than after a full backoff
            const slice_ns = @min(wake_ns - now, @as(i128, 25) * std.time.ns_per_ms);
            const slice_ms: u32 = @intCast(@divTrunc(slice_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms));
            const d: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(slice_ms), .clock = .awake };
            d.sleep(self.io) catch {};
        }
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
        // #14: control messages share the audio thread too. Queue behind any
        // in-flight upload tail instead of waiting for the peer to read.
        self.conn.?.queueMessage(mtype, payload) catch |e| {
            self.markConnectionLost("control write failed: {s}", .{@errorName(e)});
            return error.ConnectionLost;
        };
        self.stats.msgs_sent += 1;
        self.stats.bytes_sent += payload.len + 5;
        self.last_keepalive_ms = clock.nowMs(self.io);
    }

    fn sendChatMsg(self: *Session, parms: []const []const u8) !void {
        var f = Fixed{};
        try proto.buildChat(parms, &f);
        try self.send(proto.MSG_CHAT_MESSAGE, f.slice());
    }

    fn sendKeepaliveIfDue(self: *Session, now_ms: i64) !void {
        const idle_ms = now_ms - self.last_keepalive_ms;
        if (idle_ms >= @as(i64, @intCast(self.keepalive_s)) * 1000) {
            try self.send(proto.MSG_KEEPALIVE, "");
            self.log.line("C>S KEEPALIVE (idle {d}ms)", .{idle_ms});
        }
    }

    // ---- upload path (§6.5) ---------------------------------------------------

    fn startIntervalEncoders(self: *Session) !void {
        self.drop_marked = false;
        if (self.opts.plan) |pl| {
            const broadcast = pl.selectFor(pl.ctx, self.index.grid);
            for (self.locals) |*lc| lc.broadcast = broadcast;
        }
        for (self.locals) |*lc| {
            if (lc.enc) |e| {
                e.destroy();
                lc.enc = null;
            }
            lc.pending.clear();
            lc.dump.clear();
            lc.begun = false;
            lc.produced = 0;
            lc.dropped = false;
            var serial: u32 = 0;
            if (self.opts.id_seed) |seed| {
                // deterministic ids: byte-identical payloads across runs
                const ci = self.channelIndex(lc);
                // kujamba (#12): ids key off the monotonic sequence, so a grid
                // re-anchor can never re-issue a guid already sent this session
                instrument.deriveGuid(seed, self.index.seq, ci, &lc.guid);
                serial = instrument.deriveSerial(seed, self.index.seq, ci);
            } else {
                self.io.random(&lc.guid);
                self.io.random(std.mem.asBytes(&serial));
            }
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
        const elapsed_ns = @max(0, now_ns - self.interval_start_ns);
        const elapsed_samples: u64 = @intCast(@divFloor(elapsed_ns * @as(i128, self.opts.srate), 1_000_000_000));
        // kujamba (#13): the encode target leads the wall clock by a bounded
        // margin, so the last block is already encoded — and the flush and the
        // final 0x84 chunk already in flight — when the boundary arrives, rather
        // than starting at it. This changes *when* a bar is generated, never
        // *what*: the sample sequence, the block sizes and therefore the encoded
        // bytes are identical, so the determinism evidence is untouched.
        const lead = self.timing.encodeLeadSamples(self.interval_len_samples);
        const target = @min(elapsed_samples +| lead, self.interval_len_samples);

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
                encodeBlockFor(self.opts.source, self.opts.srate, lc, if (self.dev != null) live_block[0..n] else null, block[0..n]);
                // #14: keep the source/playhead and capture clock moving after
                // a drop, but do not encode or retain the rest of a lost bar.
                if (lc.dropped) continue;
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
                if (lc.dropped) continue;
                while (lc.begun and lc.pending.len >= chunk_flush_bytes) {
                    if (!try self.sendUploadChunk(lc, false)) break;
                }
                if (!lc.begun and !lc.dropped and lc.pending.len >= chunk_flush_bytes) {
                    // first chunk of the interval: send held 0x83 then data
                    if (!try self.sendUploadBegin(lc)) continue;
                    _ = try self.sendUploadChunk(lc, false);
                }
            }
        }

        if (self.locals[0].produced >= self.interval_len_samples) {
            try self.finalizeInterval();
        }
    }

    /// #14: attempt a frame without waiting. On a short write Conn owns the
    /// mandatory frame tail; the caller abandons the rest of the interval.
    fn sendUpload(self: *Session, mtype: u8, payload: []const u8) !netmod.WriteOutcome {
        const t0 = clock.nowNs(self.io);
        defer self.noteUploadStall(clock.nowNs(self.io) - t0);
        const conn = &(self.conn orelse return .declined);
        const outcome = conn.trySendMessage(mtype, payload) catch |e| {
            self.markConnectionLost("upload write failed: {s}", .{@errorName(e)});
            return error.ConnectionLost;
        };
        if (outcome == .declined) return outcome;
        self.stats.msgs_sent += 1;
        self.stats.bytes_sent += payload.len + 5;
        self.last_keepalive_ms = clock.nowMs(self.io);
        return outcome;
    }

    /// #14: abandon this channel's bar because the socket would block.
    ///
    /// The audio keeps running. That is the whole point of the issue: a bar is
    /// worth one bar of audio, and a socket that cannot take it right now cannot
    /// be made to take it by waiting — the audio clock has no slack to spend.
    /// So the bytes are counted and thrown away, the channel is left `dropped`
    /// so `finalizeInterval` sends nothing more for it (not even a silence
    /// marker: this bar had audio, and claiming otherwise would be a lie the
    /// room would hear as a rest), and the session moves on to the next bar with
    /// a fresh guid.
    fn dropInterval(self: *Session, lc: *LocalChannel, reason: []const u8) void {
        if (lc.dropped) return;
        const discarded = lc.pending.len;
        lc.dropped = true;
        lc.begun = false;
        if (lc.enc) |e| {
            e.destroy();
            lc.enc = null;
        }
        lc.pending.clear();
        lc.dump.clear();
        // Every channel's unsent bytes count, even though the bar counts once.
        // Dumps are already accepted bytes, not bytes discarded from the wire.
        self.stats.upload_bytes_dropped += discarded;
        // count once per bar, not once per channel: a dropped bar is one lost
        // bar, and counting per channel would report N losses for one silence
        if (!self.drop_marked) {
            self.drop_marked = true;
            self.stats.intervals_dropped += 1;
            self.stats.intervals_backpressured += 1;
        }
        self.log.line("UPLOAD DROPPED: {s} — bar {d} channel {d} skipped (socket would block, {d} bytes discarded); continuing at the next bar", .{
            reason, self.index.seq, self.channelIndex(lc), discarded,
        });
    }

    fn sendUploadBegin(self: *Session, lc: *LocalChannel) !bool {
        var f = Fixed{};
        try proto.buildUploadIntervalBegin(.{
            .guid = lc.guid,
            .estsize = 0,
            .fourcc = proto.FOURCC_OGGV,
            .chidx = @intCast(self.channelIndex(lc)),
        }, &f);
        if (try self.sendUpload(proto.MSG_UPLOAD_INTERVAL_BEGIN, f.slice()) != .sent) {
            self.dropInterval(lc, "0x83 would block");
            return false;
        }
        lc.begun = true;
        self.log.line("C>S 0x83 UPLOAD_BEGIN guid={s} chidx={d} interval={d}", .{
            // kujamba (#12): the guid's sequence number, not the grid position
            hexBuf(&lc.guid, &self.hex_scratch), self.channelIndex(lc), self.index.seq,
        });
        return true;
    }

    fn channelIndex(self: *Session, lc: *LocalChannel) usize {
        return (@intFromPtr(lc) - @intFromPtr(self.locals.ptr)) / @sizeOf(LocalChannel);
    }

    /// #14: record how long one interval's upload section took. The max is the
    /// number that matters — one slow peer is survivable, a stall measured in
    /// whole bars is the audio clock being eaten by the network.
    fn noteUploadStall(self: *Session, ns: i128) void {
        if (ns <= 0) return;
        const u: u64 = @intCast(ns);
        if (u > self.stats.upload_stall_ns) self.stats.upload_stall_ns = u;
    }

    /// #13: copy the clock's private drift ledger into `Stats`, which is what
    /// `RESULT` prints and what a test can read.
    fn publishClockTelemetry(self: *Session) void {
        self.stats.drift_ns = self.timing.drift_ns;
        self.stats.max_abs_drift_ns = self.timing.max_abs_drift_ns;
        self.stats.clock_corrections = self.timing.corrections;
        self.stats.total_correction_ns = self.timing.total_correction_ns;
    }

    /// #14: returns false when the bar was abandoned mid-transfer.
    fn sendUploadChunk(self: *Session, lc: *LocalChannel, final: bool) !bool {
        // payload cap: 16384 - 17 = 16367 bytes per write message
        const cap: usize = 16367;
        var remaining = lc.pending.items();
        if (remaining.len == 0) {
            if (!final) return true;
            // must terminate the transfer even with no data: empty write
            var f0 = Fixed{};
            try proto.buildUploadIntervalWrite(.{ .guid = lc.guid, .flags = 1, .data = "" }, &f0);
            if (try self.sendUpload(proto.MSG_UPLOAD_INTERVAL_WRITE, f0.slice()) != .sent) {
                self.dropInterval(lc, "final 0x84 would block");
                return false;
            }
            self.stats.upload_chunks += 1;
            self.log.line("C>S 0x84 WRITE guid={s} flags=1 bytes=0 (final)", .{hexBuf(&lc.guid, &self.hex_scratch)});
            return true;
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
            const outcome = try self.sendUpload(proto.MSG_UPLOAD_INTERVAL_WRITE, f.slice());
            if (outcome == .declined) {
                lc.pending.len = remaining.len;
                self.dropInterval(lc, "0x84 would block");
                return false;
            }
            self.stats.upload_chunks += 1;
            self.stats.upload_bytes += n;
            if (outcome == .pending) {
                // This frame is owned by Conn and will finish asynchronously;
                // only the bytes AFTER it are discarded. Never splice a new
                // guid/control frame into its missing tail.
                lc.pending.len = remaining.len - n;
                self.dropInterval(lc, "0x84 tail pending");
                return false;
            }
            if (self.opts.payload_dump_dir != null) try lc.dump.add(remaining[0..n]);
            self.log.line("C>S 0x84 WRITE guid={s} flags={d} bytes={d}", .{
                hexBuf(&lc.guid, &self.hex_scratch), @as(u8, if (final and is_last) 1 else 0), n,
            });
            remaining = remaining[n..];
        }
        lc.pending.clear();
        return true;
    }

    /// Write the interval's concatenated 0x84 payload bytes to
    /// `<dump_dir>/interval_NNNN.ogg` (determinism evidence for the demo).
    fn writePayloadDump(self: *Session, lc: *LocalChannel, dump_dir: []const u8) !void {
        if (lc.dump.len == 0) return;
        defer lc.dump.clear();
        // kujamba (#12): name by monotonic sequence, so a grid re-anchor cannot
        // overwrite an earlier interval's dump
        const path = instrument.payloadDumpName(self.alloc, dump_dir, self.index.seq) catch return;
        defer self.alloc.free(path);
        if (std.Io.Dir.cwd().createFile(self.io, path, .{})) |f| {
            var wrote_ok = true;
            f.writeStreamingAll(self.io, lc.dump.items()) catch |e| {
                wrote_ok = false;
                self.log.line("payload dump write failed ({s}): {s}", .{ path, @errorName(e) });
            };
            f.close(self.io);
            if (wrote_ok) {
                self.stats.payload_dumps += 1;
                self.log.line("payload dump {s} bytes={d}", .{ path, lc.dump.len });
            }
        } else |e| {
            self.log.line("payload dump open failed ({s}): {s}", .{ path, @errorName(e) });
        }
    }

    fn finalizeInterval(self: *Session) !void {
        try self.finishInterval(true);
    }

    fn finishInterval(self: *Session, start_next: bool) !void {
        // #13/#14 telemetry: wall time the upload section of ONE interval takes.
        // The audio clock regenerates a whole bar per interval, so this is the
        // number that says whether a slow peer can starve it.
        const stall_start_ns = clock.nowNs(self.io);
        defer self.noteUploadStall(clock.nowNs(self.io) - stall_start_ns);

        // kujamba (#13): this is the instant the bar boundary was crossed, and
        // it is what the clock's drift is measured against. Taken BEFORE the
        // upload work below so the wire time is charged to the socket, not
        // disguised as late generation.
        const boundary_ns = stall_start_ns;

        for (self.locals) |*lc| {
            // #14: a channel whose bar was abandoned mid-interval sends nothing
            // further this bar — not the tail, and not a silence marker, because
            // this bar had audio and saying otherwise would be a lie the room
            // hears as a rest.
            if (lc.dropped) continue;
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
                        if (try self.sendUpload(proto.MSG_UPLOAD_INTERVAL_BEGIN, f.slice()) != .sent) {
                            self.dropInterval(lc, "silence marker would block");
                            continue;
                        }
                        self.stats.silence_markers += 1;
                        self.log.line("C>S 0x83 SILENCE_MARKER chidx={d}", .{self.channelIndex(lc)});
                    } else {
                        _ = try self.sendUploadBegin(lc);
                    }
                }
                if (lc.dropped) continue;
                if (!try self.sendUploadChunk(lc, true)) continue;
                if (self.opts.payload_dump_dir) |dump_dir| {
                    try self.writePayloadDump(lc, dump_dir);
                }
            } else {
                // channel not broadcasting: periodic silence marker (§6.5.4)
                var f = Fixed{};
                try proto.buildUploadIntervalBegin(.{
                    .guid = [_]u8{0} ** 16,
                    .estsize = 0,
                    .fourcc = 0,
                    .chidx = @intCast(self.channelIndex(lc)),
                }, &f);
                if (try self.sendUpload(proto.MSG_UPLOAD_INTERVAL_BEGIN, f.slice()) != .sent) {
                    self.dropInterval(lc, "silence marker would block");
                    continue;
                }
                self.stats.silence_markers += 1;
                self.log.line("C>S 0x83 SILENCE_MARKER chidx={d}", .{self.channelIndex(lc)});
            }
        }
        var streaming: u64 = 0;
        var dropped_here = false;
        for (self.locals) |lc| {
            // A dropped channel did not stream, so it is not counted as
            // broadcast: `intervals_broadcast` is what the demo asserts on and
            // it must keep meaning "this bar really went out".
            if (lc.broadcast and !lc.dropped) streaming += 1;
            if (lc.dropped) dropped_here = true;
        }
        if (dropped_here) {
            self.log.line("interval {d} dropped ({d} channels), audio clock continues", .{ self.index.seq, self.locals.len });
        } else {
            self.stats.intervals_uploaded += 1;
            self.stats.upload_channels = @max(self.stats.upload_channels, streaming);
            self.stats.intervals_broadcast += streaming;
            self.log.line("interval {d} complete (grid bar {d}, {d} samples, {d}ms)", .{
                // kujamba (#12): seq and grid are distinct, so log both
                self.index.seq, self.index.grid, self.interval_len_samples, self.interval_len_samples * 1000 / self.opts.srate,
            });
        }
        self.index.complete();

        // kujamba (#13): the bar grid, disciplined. Before this it was
        // `interval_start_ns += interval_ns` with nothing measuring whether the
        // session was keeping up, so the time spent on the wire above was
        // silently stolen from every subsequent bar's generation budget and
        // never returned. Now the crossing time is measured against the bar's
        // nominal end and a *bounded* correction is applied — bounded twice
        // over, as a fraction of the bar and in absolute nanoseconds, so a fast
        // tempo cannot get a jumpy correction and a slow one cannot get a
        // visible one.
        const next_start_ns = self.timing.nextStartNs(self.interval_start_ns, boundary_ns);
        self.interval_start_ns = next_start_ns;
        self.publishClockTelemetry();

        if (self.opts.stop_after_intervals) |n_stop| {
            // kujamba (#12): the cap counts intervals, so it reads the
            // monotonic sequence — a config change must not extend the run
            if (self.index.seq >= n_stop) {
                self.stats.ok = true;
                self.state = .done;
                return;
            }
        }
        if (start_next) try self.startIntervalEncoders();
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
        // #41: both fields are raw wire values, and a config change is the one
        // place a client is asked to divide by one of them. bpm = 0 reached
        // @divTrunc(srate * bpi * 60, bpm) and panicked; bpi = 0 does not panic
        // but makes every interval zero-length, which turns the run loop's
        // `produced >= interval_len` into a per-pass finalize — a flood of
        // empty uploads rather than a crash. Neither is a tempo the client can
        // honour, so this is the same class as a malformed payload: fail the
        // session, the same way a parse failure does above.
        //
        // Checked BEFORE the assignments below. Bailing out after writing
        // self.bpm would leave a session that believes it is running at 0 bpm,
        // which is exactly the state that made the original panic reachable.
        if (cfg.bpm == 0 or cfg.bpi == 0) {
            self.log.line("S>C 0x02 CONFIG bpm={d} bpi={d}", .{ cfg.bpm, cfg.bpi });
            return self.failSession("bad config change: bpm and bpi must both be non-zero", .{});
        }
        const changed = cfg.bpm != self.bpm or cfg.bpi != self.bpi;
        self.bpm = cfg.bpm;
        self.bpi = cfg.bpi;
        self.log.line("S>C 0x02 CONFIG bpm={d} bpi={d}", .{ cfg.bpm, cfg.bpi });

        if (changed) {
            // finalize any in-flight interval cleanly, then adopt new timing
            if (self.interval_len_samples != 0 and self.locals[0].produced > 0) {
                try self.finishInterval(false);
                if (self.state == .done) return;
            }
            self.interval_len_samples = @intCast(@divTrunc(@as(u64, self.opts.srate) * @as(u64, cfg.bpi) * 60, @as(u64, cfg.bpm)));
            self.interval_start_ns = clock.nowNs(self.io);
            // kujamba (#13): anchor the disciplined grid on this boundary. The
            // `0x02` arrival is the only place the server ever tells the client
            // where its grid is, so it is the only place a re-anchor belongs —
            // and re-anchoring the clock (not just the start time) is what keeps
            // the drift ledger continuous across a tempo change instead of
            // quietly restarting at zero.
            self.timing.anchor(self.interval_start_ns, cfg.bpm, cfg.bpi);
            self.publishClockTelemetry();
            // kujamba (#12): only the grid geometry moves. The bar counter and
            // the phrase cursor stay put, and the interval sequence keeps
            // climbing, so no guid repeats and no payload dump is overwritten.
            self.dropCapturePreRoll();
            try self.startIntervalEncoders();
            self.log.line("interval clock started: {d} samples ({d}ms)", .{
                self.interval_len_samples, self.interval_len_samples * 1000 / self.opts.srate,
            });
            self.log.line("re-anchored to bpm={d} bpi={d}: next interval {d} at grid bar {d} (phrase continues)", .{
                cfg.bpm, cfg.bpi, self.index.seq, self.index.grid,
            });
            self.log.line("server clock: bar={d}ns slew limit={d}ms lead={d} samples", .{
                self.timing.interval_ns,
                @divTrunc(self.timing.slewLimitNs(), std.time.ns_per_ms),
                self.timing.encodeLeadSamples(self.interval_len_samples),
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
            // #40: `channel_id` is a raw wire byte and the shift below needs a
            // u5, so >= 32 panicked on @intCast. A channel outside 0..31
            // cannot name a bit in a u32 mask — the reference client's mask is
            // u32 too, so it has no legitimate meaning and there is nothing to
            // salvage. Skipping the record (not failing the session) is right:
            // one nonsense record from a quirky server should not tear down a
            // live performance, and the rest of the message is still good.
            if (rec.channel_id >= 32) {
                self.log.line("  ignoring userinfo record: channel {d} is out of range 0..31", .{rec.channel_id});
                continue;
            }
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
        if (self.opts.on_chat) |hook| hook.receive(hook.ctx, p);
    }

    // ---- main loop -------------------------------------------------------------------

    /// #14: idle polling spends only the time left until the next audio block,
    /// not a fresh 20 ms before every advance (especially on short bars).
    fn audioPollMs(self: *Session, now_ns: i128) i32 {
        if (self.state != .active or self.interval_len_samples == 0 or self.locals.len == 0) return 20;
        const next_sample = @min(self.locals[0].produced + encode_block_samples, self.interval_len_samples);
        const lead = self.timing.encodeLeadSamples(self.interval_len_samples);
        const due_ns = self.interval_start_ns +
            @divTrunc(@as(i128, next_sample -| lead) * std.time.ns_per_s, self.opts.srate);
        const left = @max(0, due_ns - now_ns);
        return @intCast(@min(20, @divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
    }

    pub fn run(self: *Session) !Stats {
        std.Io.Dir.cwd().createDirPath(self.io, self.opts.out_dir) catch {};
        if (self.opts.payload_dump_dir) |dump_dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dump_dir) catch {};
        }

        self.openLive();

        var hostbuf: [256]u8 = undefined;
        const hostport = std.fmt.bufPrint(&hostbuf, "{s}:{d}", .{ self.opts.host, self.opts.port }) catch "host";
        self.log.line("connecting to {s} as {s}", .{ hostport, self.opts.user });

        const deadline_ns = self.start_ns + @as(i128, self.opts.duration_ms) * 1_000_000;
        // kujamba (#24): reconnect dials consumed so far. The first dial is not
        // an attempt — a server that refuses the join ends the session, exactly
        // as it always has; only a connection that was LOST is retried.
        var dials_used: u32 = 0;

        // `outer` labels the run loop so a connection-loss path can jump
        // straight to the acquisition step at the top; every one of them has
        // already torn the connection down before it jumps.
        outer: while (self.state != .done) {
            // ---- acquire a connection: the first dial, or a reconnect ----
            if (self.conn == null) {
                if (self.conn_lost_ns == null) {
                    self.conn = netmod.Conn.connect(self.io, self.opts.host, self.opts.port) catch |e| {
                        return self.failSession("connect failed: {s}", .{@errorName(e)});
                    };
                    self.log.line("connected", .{});
                    self.last_keepalive_ms = clock.nowMs(self.io);
                } else {
                    // The connection was lost. Decide the budget first: a
                    // session with nothing left to try keeps its post-mortem
                    // exactly as the loss left it.
                    if (dials_used >= self.opts.reconnect_attempts) {
                        // With the default budget of 0 this is where every
                        // connection-level death lands, with the loss reason
                        // verbatim — the pre-#24 behaviour, unchanged.
                        return self.failSessionWithRecordedReason();
                    }
                    // Reconnecting: tear down everything bound to the dead
                    // connection before pricing the next attempt.
                    self.resetForReconnect();
                    const delay_ms = instrument.reconnectDelayMs(
                        dials_used,
                        self.opts.reconnect_backoff_start_ms,
                        self.opts.reconnect_backoff_max_ms,
                    );
                    self.log.line("reconnect attempt {d}/{d} in {d}ms", .{ dials_used + 1, self.opts.reconnect_attempts, delay_ms });
                    switch (self.sleepInterruptibly(delay_ms, deadline_ns)) {
                        .proceeded => {},
                        // the outage outlived the session: end it gracefully —
                        // what was uploaded before the loss still counts
                        .stopped, .expired => {
                            self.stats.outage_ms += @intCast(@divTrunc(clock.nowNs(self.io) - self.conn_lost_ns.?, 1_000_000));
                            self.conn_lost_ns = null;
                            self.log.line("giving up reconnecting: session over during outage", .{});
                            self.stats.ok = self.stats.intervals_uploaded > 0;
                            self.state = .done;
                            break;
                        },
                    }
                    dials_used += 1;
                    self.conn = netmod.Conn.connect(self.io, self.opts.host, self.opts.port) catch |e| {
                        self.log.line("reconnect dial failed: {s}", .{@errorName(e)});
                        continue; // the next backoff prices this attempt in
                    };
                    const outage = clock.nowNs(self.io) - self.conn_lost_ns.?;
                    self.stats.outage_ms += @intCast(@divTrunc(outage, 1_000_000));
                    self.conn_lost_ns = null;
                    self.stats.reconnects += 1;
                    self.stats.clearFail();
                    self.log.line("reconnected after {d}ms outage (attempt {d} of {d})", .{
                        @divTrunc(outage, 1_000_000), dials_used, self.opts.reconnect_attempts,
                    });
                    self.last_keepalive_ms = clock.nowMs(self.io);
                    self.state = .connecting;
                }
            }

            const now_ns = clock.nowNs(self.io);
            if (now_ns >= deadline_ns) {
                // kujamba instrument hook: hitting the cap with zero intervals
                // uploaded is a failed run, not a success
                self.stats.ok = self.stats.intervals_uploaded > 0;
                self.state = .done;
                break;
            }

            // kujamba instrument hook: cooperative stop (Ctrl+C) — finish the
            // current interval cleanly instead of dying mid-upload.
            if (self.stopRequested()) {
                self.log.line("stop requested: finishing current interval", .{});
                if (self.state == .active and self.interval_len_samples != 0 and
                    self.locals.len > 0 and self.locals[0].produced > 0)
                {
                    self.finishInterval(false) catch |e| switch (e) {
                        // #24: the final bar's upload tore the connection — the
                        // stop is still the stop; do not resurrect the session
                        // just to report the tear
                        error.ConnectionLost => self.log.line("final bar lost the connection on the way out", .{}),
                        else => return e,
                    };
                }
                self.stats.ok = self.stats.intervals_uploaded > 0;
                self.state = .done;
                break;
            }

            // #14: service the audio clock BEFORE network work. Writes only
            // flush available space, and input dispatch is capped per pass.
            _ = self.conn.?.flushWrites() catch |e| {
                self.markConnectionLost("write flush failed: {s}", .{@errorName(e)});
                continue :outer;
            };
            if (self.state == .active) {
                const now2 = clock.nowNs(self.io);
                self.advanceAudio(now2) catch |e| switch (e) {
                    error.SessionFailed => {},
                    // #24: the connection died under the audio engine (a torn
                    // upload frame is the realistic case). Everything is
                    // already torn down; go dial a new one.
                    error.ConnectionLost => continue :outer,
                    else => return self.failSession("audio advance failed: {s}", .{@errorName(e)}),
                };
                if (self.state == .done) break;
                if (self.conn == null) continue;

                if (self.opts.chat != null and !self.chat_sent and
                    now2 - self.start_ns >= @as(i128, self.opts.chat_delay_ms) * 1_000_000)
                {
                    self.sendChatMsg(&[_][]const u8{ "MSG", self.opts.chat.? }) catch |e| switch (e) {
                        error.ConnectionLost => continue :outer,
                        else => return self.failSession("chat send failed: {s}", .{@errorName(e)}),
                    };
                    self.chat_sent = true;
                    self.stats.chat_sent += 1;
                    self.log.line("C>S 0xC0 CHAT MSG: {s}", .{self.opts.chat.?});
                }
            }

            var dispatched: usize = 0;
            while (dispatched < 32 and self.state != .done) : (dispatched += 1) {
                // Try buffered frames as well as fd-readable ones. A previous
                // read may have buffered several messages before EAGAIN.
                const msg = self.conn.?.readMessage(&self.payload) catch |e| switch (e) {
                    error.WouldBlock => break,
                    else => {
                        self.markConnectionLost("read failed: {s}", .{@errorName(e)});
                        continue :outer;
                    },
                };
                self.dispatch(msg) catch |e| switch (e) {
                    error.SessionFailed => return e,
                    error.ConnectionLost => continue :outer,
                    else => return e,
                };
            }
            if (self.state == .done) break;
            const now_ms = clock.nowMs(self.io);
            if (now_ms - self.conn.?.last_recv_ms > @as(i64, @intCast(self.keepalive_s)) * 3000) {
                self.markConnectionLost("connection stalled: no data for {d}ms", .{now_ms - self.conn.?.last_recv_ms});
                continue :outer;
            }
            if (self.state == .active) self.sendKeepaliveIfDue(now_ms) catch continue :outer;
            if (dispatched < 32) {
                const poll_ns = clock.nowNs(self.io);
                const deadline_ms: i32 = @intCast(@min(20, @max(0, @divTrunc(deadline_ns - poll_ns, std.time.ns_per_ms))));
                const wait_ms = @min(self.audioPollMs(poll_ns), deadline_ms);
                _ = self.conn.?.pollReadable(wait_ms) catch |e| {
                    self.markConnectionLost("poll failed: {s}", .{@errorName(e)});
                    continue :outer;
                };
            }
        }

        // a session that ends mid-outage still reports the outage it suffered
        if (self.conn_lost_ns) |t0| {
            self.stats.outage_ms += @intCast(@divTrunc(clock.nowNs(self.io) - t0, 1_000_000));
            self.conn_lost_ns = null;
        }

        self.closeWavs();
        self.closeLive();
        self.log.line("session end: ok={}", .{self.stats.ok});
        return self.stats;
    }

    fn stopRequested(self: *const Session) bool {
        if (self.opts.stop) |hook| return hook.requested(hook.ctx);
        return false;
    }

    /// Test-only seams for adapter regressions. Production users drive run().
    pub const Testing = if (@import("builtin").is_test) struct {
        pub const Channel = LocalChannel;
        pub const dispatch = Session.dispatch;
        pub const startIntervalEncoders = Session.startIntervalEncoders;
        pub const advanceAudio = Session.advanceAudio;
        pub const finalizeInterval = Session.finalizeInterval;
        pub const writePayloadDump = Session.writePayloadDump;
        pub const dropInterval = Session.dropInterval;
    } else struct {};
};

test "live channels share one capture block; synthetic channels retain independent phase" {
    const alloc = std.testing.allocator;
    var a = LocalChannel{ .pending = Buf.init(alloc), .dump = Buf.init(alloc) };
    defer a.pending.deinit();
    defer a.dump.deinit();
    var b = LocalChannel{ .pending = Buf.init(alloc), .dump = Buf.init(alloc) };
    defer b.pending.deinit();
    defer b.dump.deinit();
    const shared = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var first: [4]f32 = undefined;
    var second: [4]f32 = undefined;
    encodeBlockFor(.silence, 48000, &a, &shared, &first);
    encodeBlockFor(.silence, 48000, &b, &shared, &second);
    try std.testing.expectEqualSlices(f32, &shared, &first);
    try std.testing.expectEqualSlices(f32, &first, &second);
    const tone = Source{ .tone = .{ .freq = 440, .amp = 0.5 } };
    encodeBlockFor(tone, 48000, &a, null, &first);
    encodeBlockFor(tone, 48000, &b, null, &second);
    try std.testing.expectEqualSlices(f32, &first, &second);
    encodeBlockFor(tone, 48000, &a, null, &first);
    try std.testing.expect(a.phase != b.phase);
}

test "custom source and interval hook apply pending changes only at a bar boundary, including rests" {
    const Fixture = struct {
        value: f32 = 0.25,
        pending: f32 = 0.25,
        frames: u64 = 0,
        selections: u64 = 0,

        fn fill(ctx: *anyopaque, _: u64, samples: []f32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memset(samples, self.value);
            self.frames += samples.len;
        }

        fn select(ctx: *anyopaque, grid: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.value = self.pending;
            self.selections += 1;
            return grid % 2 == 0;
        }
    };
    var fixture = Fixture{};
    var s = try Session.init(std.testing.allocator, std.testing.io, .{
        .source = .{ .custom = .{ .ctx = &fixture, .fill = Fixture.fill } },
        .plan = .{ .ctx = &fixture, .selectFor = Fixture.select },
        .id_seed = 42,
    });
    defer s.deinit();
    s.interval_len_samples = 480;
    try s.startIntervalEncoders();
    var samples: [4]f32 = undefined;
    encodeBlockFor(s.opts.source, s.opts.srate, &s.locals[0], null, &samples);
    try std.testing.expectEqual(@as(f32, 0.25), samples[0]);
    fixture.pending = 0.5;
    encodeBlockFor(s.opts.source, s.opts.srate, &s.locals[0], null, &samples);
    try std.testing.expectEqual(@as(f32, 0.25), samples[0]);
    s.index.complete();
    try s.startIntervalEncoders();
    try std.testing.expect(!s.locals[0].broadcast);
    try std.testing.expectEqual(@as(f32, 0.5), fixture.value);
    try std.testing.expectEqual(@as(u64, 8), fixture.frames);
    try std.testing.expectEqual(@as(u64, 2), fixture.selections);
}

test "raw chat callback preserves all fields without interpreting application commands" {
    const Fixture = struct {
        calls: u32 = 0,
        correct: bool = false,
        fn receive(ctx: *anyopaque, message: proto.ChatParms) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.correct = std.mem.eql(u8, message.get(0), "MSG") and
                std.mem.eql(u8, message.get(1), "alice") and
                std.mem.eql(u8, message.get(2), "application-specific command");
        }
    };
    var fixture = Fixture{};
    var s = try Session.init(std.testing.allocator, std.testing.io, .{
        .on_chat = .{ .ctx = &fixture, .receive = Fixture.receive },
    });
    defer s.deinit();
    s.log.quiet = true;
    var chat = Fixed{};
    try proto.buildChat(&.{ "MSG", "alice", "application-specific command" }, &chat);
    try s.dispatch(.{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });
    try std.testing.expectEqual(@as(u32, 1), fixture.calls);
    try std.testing.expect(fixture.correct);
    s.opts.on_chat = null;
    try s.dispatch(.{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });
    try std.testing.expectEqual(@as(u32, 1), fixture.calls);
}

test "mid-bar config selects the next interval once, and never past the interval cap" {
    const Fixture = struct {
        selections: u64 = 0,
        grid: u64 = 0,
        fn select(ctx: *anyopaque, grid: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.selections += 1;
            self.grid = grid;
            return false; // A rest still generates audio and crosses boundaries.
        }
    };
    for ([_]bool{ false, true }) |capped| {
        var fixture = Fixture{};
        var s = try Session.init(std.testing.allocator, std.testing.io, .{
            .plan = .{ .ctx = &fixture, .selectFor = Fixture.select },
            .stop_after_intervals = if (capped) 1 else null,
        });
        defer s.deinit();
        s.log.quiet = true;
        var fds: [2]std.posix.socket_t = undefined;
        const rc = std.posix.system.socketpair(@intCast(std.posix.AF.UNIX), @intCast(std.posix.SOCK.STREAM), 0, &fds);
        if (std.posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
        defer _ = std.c.close(fds[1]);
        s.conn = .{ .io = s.io, .fd = fds[0] };
        s.state = .active;
        var config = Fixed{};
        try proto.buildConfig(.{ .bpm = 120, .bpi = 4 }, &config);
        try s.onConfig(config.slice());
        try std.testing.expectEqual(@as(u64, 1), fixture.selections);
        s.locals[0].produced = 64;
        try proto.buildConfig(.{ .bpm = 100, .bpi = 4 }, &config);
        try s.onConfig(config.slice());
        try std.testing.expectEqual(@as(u64, 1), s.index.seq);
        try std.testing.expectEqual(@as(u64, if (capped) 1 else 2), fixture.selections);
        try std.testing.expectEqual(@as(u64, if (capped) 0 else 1), fixture.grid);
        const expected: @TypeOf(s.state) = if (capped) .done else .active;
        try std.testing.expectEqual(expected, s.state);
    }
}

test "stop callback interrupts reconnect backoff; reset preserves monotonic identity" {
    const Fixture = struct {
        fn requested(ctx: ?*anyopaque) bool {
            const stop: *bool = @ptrCast(@alignCast(ctx.?));
            return stop.*;
        }
    };
    var stop = true;
    var s = try Session.init(std.testing.allocator, std.testing.io, .{
        .stop = .{ .ctx = &stop, .requested = Fixture.requested },
    });
    defer s.deinit();
    s.log.quiet = true;
    const t0 = clock.nowNs(s.io);
    try std.testing.expectEqual(.stopped, s.sleepInterruptibly(8000, t0 + 10 * std.time.ns_per_s));
    try std.testing.expect(clock.nowNs(s.io) - t0 < 500 * std.time.ns_per_ms);
    s.index = .{ .seq = 9, .grid = 12 };
    s.resetForReconnect();
    try std.testing.expectEqual(@as(u64, 9), s.index.seq);
    try std.testing.expectEqual(@as(u64, 0), s.index.grid);
    s.opts.stop = null;
    try std.testing.expect(!s.stopRequested());
}

test "hostile channel IDs and zero tempo are rejected without undefined shifts or division" {
    var s = try Session.init(std.testing.allocator, std.testing.io, .{});
    defer s.deinit();
    s.log.quiet = true;
    var f = Fixed{};
    try proto.buildUserinfoRecord(.{
        .active = true,
        .channel_id = 200,
        .volume = 0,
        .pan = 0,
        .flags = 0,
        .username = "peer",
        .channel_name = "invalid",
    }, &f);
    try s.dispatch(.{ .mtype = proto.MSG_USERINFO_CHANGE_NOTIFY, .payload = f.slice() });
    for (s.users) |user| try std.testing.expectEqual(@as(u32, 0), user.mask);
    try std.testing.expectEqual(@as(u64, 0), s.stats.msgs_sent);
    try proto.buildConfig(.{ .bpm = 0, .bpi = 4 }, &f);
    try std.testing.expectError(error.SessionFailed, s.dispatch(.{
        .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY,
        .payload = f.slice(),
    }));
    try proto.buildConfig(.{ .bpm = 120, .bpi = 0 }, &f);
    try std.testing.expectError(error.SessionFailed, s.dispatch(.{
        .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY,
        .payload = f.slice(),
    }));
    try std.testing.expectEqual(@as(u64, 0), s.interval_len_samples);
}
