//! Phase B: live audio in/out via vendored miniaudio (single header).
//!
//! miniaudio.h is 4 MB of macro soup and does not survive translate-c, so it
//! is compiled in exactly one C TU (vendor/miniaudio_impl.c) behind a tiny
//! shim; this file only declares those entry points. One duplex device:
//! capture feeds the upload ring, playback drains the decoded-peer ring.
//! Rings are mutex-guarded f32 FIFOs shared by the audio thread and the
//! session loop.

const std = @import("std");
const build_options = @import("build_options");

/// Compiled in? (build option `-Dlive`, default on when targeting macOS)
pub const enabled: bool = build_options.live;

/// Error code of the most recent failed `Device.open`; 0 = none/failed since.
pub var last_open_error: c_int = 0;

extern fn zc_device_open(
    out: *?*anyopaque,
    srate: c_uint,
    period_frames: c_uint,
    fill: *const fn (?*anyopaque, ?[*]f32, ?[*]const f32, c_uint) callconv(.c) void,
    user: ?*anyopaque,
    device_id: ?[*:0]const u8,
) c_int;
extern fn zc_device_close(handle: ?*anyopaque) void;
extern fn zc_device_sample_rate(handle: ?*anyopaque) c_uint;
extern fn zc_device_name(handle: ?*anyopaque) [*:0]const u8;
extern fn zc_backend_name(handle: ?*anyopaque) [*:0]const u8;
extern fn zc_device_frames_seen(handle: ?*anyopaque) u64;
extern fn zc_error_string(code: c_int) [*:0]const u8;
extern fn zc_probe(backend: ?[*:0]const u8, out_srate: *c_uint, name_buf: [*]u8, name_cap: c_uint) c_int;

/// Seconds of captured audio the device thread runs ahead of the session
/// thread. The session pulls in 20 ms blocks driven by the interval clock, so
/// without a margin it constantly finds the ring short by one device period
/// and zero-fills; a jitter buffer turns that into jitter instead of dropouts.
const capture_jitter_seconds: f32 = 0.1;

/// Capacity of the capture ring. Only `capture_jitter_seconds` of it is ever
/// *intended* to be queued; the rest absorbs session-thread stalls (a blocking
/// socket write) so a hiccup costs latency instead of mic audio.
const capture_ring_seconds: f32 = 8.0;

/// Seconds of decoded peer audio kept queued. A NINJAM interval is decoded and
/// pushed in one burst, so this must exceed the longest interval or playback
/// drops its head (60 bpm x 16 bpi is already 16 s; slower jams exist).
const playback_ring_seconds: f32 = 30.0;

pub const Ring = struct {
    buf: []f32,
    read_pos: usize = 0,
    write_pos: usize = 0,
    count: usize = 0,
    /// pthread mutex: the audio thread must be able to block on the session
    /// thread, which a spinlock cannot do without burning its deadline.
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    underruns: u64 = 0,
    overruns: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, capacity_frames: usize) !Ring {
        return .{ .buf = try alloc.alloc(f32, capacity_frames) };
    }

    pub fn deinit(self: *Ring, alloc: std.mem.Allocator) void {
        _ = std.c.pthread_mutex_destroy(&self.mutex);
        alloc.free(self.buf);
    }

    fn lock(self: *Ring) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }

    fn unlock(self: *Ring) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    pub fn push(self: *Ring, data: []const f32) void {
        if (self.buf.len == 0) return;
        self.lock();
        defer self.unlock();
        for (data) |v| {
            if (self.count == self.buf.len) {
                self.overruns += 1;
                // drop oldest to keep latency bounded
                self.read_pos = (self.read_pos + 1) % self.buf.len;
                self.count -= 1;
            }
            self.buf[self.write_pos] = v;
            self.write_pos = (self.write_pos + 1) % self.buf.len;
            self.count += 1;
        }
    }

    /// Read real frames into the front of `out`; returns how many. The tail is
    /// left untouched (the caller decides what an unfilled slot means).
    pub fn pullInto(self: *Ring, out: []f32) usize {
        if (self.buf.len == 0) return 0;
        self.lock();
        defer self.unlock();
        const n = @min(out.len, self.count);
        for (out[0..n]) |*slot| {
            slot.* = self.buf[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.buf.len;
        }
        self.count -= n;
        return n;
    }

    /// Fill `out` entirely; returns how many frames were real samples (a
    /// short result means the ring ran dry and the tail was zero-filled).
    pub fn pull(self: *Ring, out: []f32) usize {
        const real = self.pullInto(out);
        for (out[real..]) |*slot| {
            self.underruns += 1;
            slot.* = 0;
        }
        return real;
    }

    fn queued(self: *Ring) usize {
        self.lock();
        defer self.unlock();
        return self.count;
    }

    /// Drop all queued frames; returns how many.
    fn flush(self: *Ring) usize {
        self.lock();
        defer self.unlock();
        const n = self.count;
        self.read_pos = 0;
        self.write_pos = 0;
        self.count = 0;
        return n;
    }
};

/// Linear sample-rate converter used only when the device refuses the
/// session rate (44.1 kHz speakers under a 48 kHz server, typically).
/// `pos` persists across calls so the phase does not restart every block.
pub const Resampler = struct {
    src_rate: u32,
    dst_rate: u32,
    step: f64,
    pos: f64 = 0,

    pub fn init(src_rate: u32, dst_rate: u32) Resampler {
        return .{
            .src_rate = src_rate,
            .dst_rate = dst_rate,
            .step = @as(f64, @floatFromInt(src_rate)) / @as(f64, @floatFromInt(dst_rate)),
        };
    }

    /// src: `src_rate` mono frames. dst: `dst_rate` mono frames.
    pub fn process(self: *Resampler, src: []const f32, dst: []f32) void {
        if (src.len == 0 or dst.len == 0) return;
        const n: f64 = @floatFromInt(src.len);
        for (dst) |*out| {
            const idx: usize = @intFromFloat(@floor(self.pos));
            const frac: f32 = @floatCast(self.pos - @floor(self.pos));
            const cur: f32 = src[@min(idx, src.len - 1)];
            const next: f32 = src[@min(idx + 1, src.len - 1)];
            out.* = cur + (next - cur) * frac;
            self.pos += self.step;
            while (self.pos >= n) self.pos -= n;
        }
    }
};

fn onData(
    user: ?*anyopaque,
    out: ?[*]f32,
    inp: ?[*]const f32,
    frame_count: c_uint,
) callconv(.c) void {
    const dev: *Device = @ptrCast(@alignCast(user orelse return));
    const n: usize = @intCast(frame_count);
    if (n == 0) return;
    if (inp) |ins| dev.pushCapture(ins[0..n]);
    if (out) |outs| dev.pullPlayback(outs[0..n]);
}

pub const Device = struct {
    handle: ?*anyopaque = null,
    /// mic capture -> upload encoder
    tx: Ring,
    /// decoded peer mix -> speakers
    rx: Ring,
    srate: u32,
    dev_srate: u32 = 0,
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    /// non-null only when the device runs at a different rate than the session
    tx_rs: ?Resampler = null,
    rx_rs: ?Resampler = null,
    /// capture frames the device is allowed to run ahead of the session thread
    jitter_frames: usize = 0,

    pub fn nameSlice(self: *const Device) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Open the default duplex device at `srate`. Caller falls back to a
    /// synthetic source when this fails (no device / no permission); the
    /// miniaudio error code is left in `last_open_error`.
    pub fn open(alloc: std.mem.Allocator, srate: u32, period_frames: u32, device_id: ?[*:0]const u8) !*Device {
        const self = try alloc.create(Device);
        var tx = Ring.init(alloc, @intFromFloat(@as(f32, @floatFromInt(srate)) * capture_ring_seconds)) catch |e| {
            alloc.destroy(self);
            return e;
        };
        const rx = Ring.init(alloc, @intFromFloat(@as(f32, @floatFromInt(srate)) * playback_ring_seconds)) catch |e| {
            tx.deinit(alloc);
            alloc.destroy(self);
            return e;
        };
        self.* = .{ .tx = tx, .rx = rx, .srate = srate, .jitter_frames = @intFromFloat(@as(f32, @floatFromInt(srate)) * capture_jitter_seconds) };

        var handle: ?*anyopaque = null;
        const rc = zc_device_open(&handle, srate, period_frames, &onData, self, device_id);
        if (rc != 0 or handle == null) {
            last_open_error = rc;
            self.deinit(alloc);
            return error.DeviceOpenFailed;
        }
        last_open_error = 0;
        self.handle = handle;
        self.dev_srate = zc_device_sample_rate(handle);
        const cname = zc_device_name(handle);
        var n: usize = 0;
        while (n < self.name_buf.len and cname[n] != 0) : (n += 1) self.name_buf[n] = cname[n];
        self.name_len = n;
        if (self.dev_srate != 0 and self.dev_srate != srate) {
            self.tx_rs = Resampler.init(self.dev_srate, srate);
            self.rx_rs = Resampler.init(srate, self.dev_srate);
        }
        return self;
    }

    pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
        if (self.handle != null) {
            zc_device_close(self.handle);
            self.handle = null;
        }
        self.tx.deinit(alloc);
        self.rx.deinit(alloc);
        alloc.destroy(self);
    }

    pub fn backend(self: *const Device) []const u8 {
        return std.mem.span(zc_backend_name(self.handle));
    }

    pub fn framesSeen(self: *const Device) u64 {
        return zc_device_frames_seen(self.handle);
    }

    pub fn lastError(code: c_int) []const u8 {
        return std.mem.span(zc_error_string(code));
    }

    /// Default playback device name + native rate (diagnostics only).
    pub fn probePlayback(out: []u8) struct { srate: u32, name: []const u8 } {
        if (out.len == 0) return .{ .srate = 0, .name = "" };
        var srate: c_uint = 0;
        const rc = zc_probe(null, &srate, out.ptr, @intCast(out.len));
        if (rc != 0) return .{ .srate = 0, .name = "" };
        out[out.len - 1] = 0;
        return .{ .srate = srate, .name = std.mem.span(@as([*:0]const u8, @ptrCast(out.ptr))) };
    }

    // ---- real-time path (miniaudio audio thread) ------------------------------

    fn pushCapture(self: *Device, frames: []const f32) void {
        if (self.tx_rs) |*rs| {
            var scratch: [512]f32 = undefined;
            var done: usize = 0;
            while (done < frames.len) {
                const take = @min(scratch.len, frames.len - done);
                rs.process(frames[done..][0..take], scratch[0..take]);
                self.tx.push(scratch[0..take]);
                done += take;
            }
            return;
        }
        self.tx.push(frames);
    }

    fn pullPlayback(self: *Device, out: []f32) void {
        if (self.rx_rs) |*rs| {
            var scratch: [512]f32 = undefined;
            var done: usize = 0;
            while (done < out.len) {
                const take = @min(scratch.len, out.len - done);
                rs.process(out[done..][0..take], scratch[0..take]);
                _ = self.rx.pull(out[done..][0..take]);
                done += take;
            }
            return;
        }
        _ = self.rx.pull(out);
    }

    // ---- session thread -------------------------------------------------------

    /// Pull captured frames, leaving the ring running `jitter_frames` ahead of
    /// the session thread; `out` is always filled, and the return value is how
    /// much of it was real capture (the rest is zero-filled silence).
    pub fn readCapture(self: *Device, out: []f32) usize {
        const avail = self.tx.queued();
        const want: usize = if (avail > self.jitter_frames) @min(out.len, avail - self.jitter_frames) else 0;
        const got = self.tx.pullInto(out[0..want]);
        for (out[got..]) |*slot| {
            self.tx.underruns += 1;
            slot.* = 0;
        }
        return got;
    }

    /// Queue decoded peer audio for playback.
    pub fn writePlayback(self: *Device, data: []const f32) void {
        self.rx.push(data);
    }

    /// Throw away everything captured so far (used to drop the pre-roll that
    /// accumulates between opening the device and the first interval).
    pub fn flushCapture(self: *Device) usize {
        return self.tx.flush();
    }

    pub fn queuedCapture(self: *Device) usize {
        return self.tx.queued();
    }

    pub fn queuedPlayback(self: *Device) usize {
        return self.rx.queued();
    }

    pub fn underruns(self: *const Device) u64 {
        return self.tx.underruns + self.rx.underruns;
    }

    pub fn overruns(self: *const Device) u64 {
        return self.tx.overruns + self.rx.overruns;
    }

    /// Capture ring: underruns are dropouts in the upload, overruns are mic
    /// frames the session thread was too slow to take.
    pub fn txStats(self: *const Device) struct { under: u64, over: u64 } {
        return .{ .under = self.tx.underruns, .over = self.tx.overruns };
    }

    /// Playback ring: underruns are simply the gaps where no peer is sending,
    /// so only the overrun (dropped audio) side is a defect.
    pub fn rxStats(self: *const Device) struct { under: u64, over: u64 } {
        return .{ .under = self.rx.underruns, .over = self.rx.overruns };
    }
};

test "ring: pull returns real frames, then zero-fills on underrun" {
    var r = try Ring.init(std.testing.allocator, 8);
    defer r.deinit(std.testing.allocator);

    var out: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), r.pull(&out));
    try std.testing.expectEqual(@as(f32, 0), out[0]);

    r.push(&[_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 });
    try std.testing.expectEqual(@as(usize, 4), r.pull(&out));
    try std.testing.expectEqual(@as(f32, 0.1), out[0]);
    try std.testing.expectEqual(@as(f32, 0.4), out[3]);
    try std.testing.expectEqual(@as(usize, 1), r.pull(&out));
    try std.testing.expectEqual(@as(f32, 0.5), out[0]);
    try std.testing.expectEqual(@as(f32, 0.0), out[1]);
    try std.testing.expect(r.underruns > 0);
}

test "ring: wraparound keeps ordering, overrun drops oldest" {
    var r = try Ring.init(std.testing.allocator, 4);
    defer r.deinit(std.testing.allocator);

    for (0..8) |i| r.push(&[_]f32{@floatFromInt(i)});
    try std.testing.expectEqual(@as(u64, 4), r.overruns);

    var out: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), r.pull(&out));
    // the oldest four were dropped, so the survivors are 4..7
    try std.testing.expectEqual(@as(f32, 4), out[0]);
    try std.testing.expectEqual(@as(f32, 7), out[3]);
}

test "resampler: length scales with the rate ratio, signal survives" {
    var up = Resampler.init(24000, 48000);
    const src = [_]f32{ 0, 1, 0, -1, 0, 1 };
    var dst: [12]f32 = undefined;
    up.process(&src, &dst);
    // step 0.5: even outputs are source samples, odd ones are midpoints
    const want = [_]f32{ 0, 0.5, 1, 0.5, 0, -0.5, -1, -0.5, 0, 0.5, 1, 1 };
    for (dst, want) |got, expected| {
        try std.testing.expectApproxEqAbs(expected, got, 1e-6);
    }

    var down = Resampler.init(48000, 24000);
    const src2 = [_]f32{ 1, 1, 1, 1, 1, 1 };
    var dst2: [3]f32 = undefined;
    down.process(&src2, &dst2);
    for (dst2) |v| try std.testing.expectEqual(@as(f32, 1), v);
}

test "resampler: 2x downsample of a 1 kHz tone keeps 1 kHz energy" {
    // 48 kHz -> 24 kHz must not change the perceived frequency, only the rate
    const src_rate: u32 = 48000;
    const dst_rate: u32 = 24000;
    var rs = Resampler.init(src_rate, dst_rate);
    var input: [480]f32 = undefined;
    var output: [240]f32 = undefined;
    for (&input, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(src_rate));
        s.* = @sin(2.0 * std.math.pi * 1000.0 * t);
    }
    rs.process(&input, &output);
    var peak: f32 = 0;
    for (output) |v| peak = @max(peak, @abs(v));
    try std.testing.expect(peak > 0.99);
}
