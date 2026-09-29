//! Ogg Vorbis codec bindings.
//!  - Encoder: vendored libvorbis (vorbisenc), one mono VBR stream per local
//!    channel, matching the reference client (WDL/vorbisencdec.h).
//!  - Decoder: vendored stb_vorbis (single file), memory-buffer decode of one
//!    interval's accumulated Ogg stream.

const std = @import("std");

const c = @cImport({
    @cInclude("ogg/ogg.h");
    @cInclude("vorbis/codec.h");
    @cInclude("vorbis/vorbisenc.h");
});

pub const EncodeError = error{
    InitFailed,
    OutOfMemory,
};

// ---- stb_vorbis extern surface (implementation in vendor/stb_vorbis_impl.c) ----

pub const stb_vorbis = opaque {};

pub const StbVorbisInfo = extern struct {
    sample_rate: c_uint,
    channels: c_uint,
    setup_memory_required: c_uint,
    setup_temp_memory_required: c_uint,
    temp_memory_required: c_uint,
    max_frame_size: c_uint,
};

pub extern fn stb_vorbis_open_memory(data: [*]const u8, len: c_int, error_ret: *c_int, alloc: ?*const anyopaque) ?*stb_vorbis;
pub extern fn stb_vorbis_close(f: *stb_vorbis) void;
pub extern fn stb_vorbis_get_info(f: *stb_vorbis) StbVorbisInfo;
pub extern fn stb_vorbis_get_frame_float(f: *stb_vorbis, channels: *c_int, output: *[*][*]f32) c_int;

pub const Decoded = struct {
    alloc: std.mem.Allocator,
    srate: u32,
    channels: u32,
    /// interleaved f32, frames * channels
    pcm: []f32,

    pub fn deinit(self: *Decoded) void {
        self.alloc.free(self.pcm);
    }

    pub fn frames(self: *const Decoded) usize {
        if (self.channels == 0) return 0;
        return self.pcm.len / self.channels;
    }

    pub fn rms(self: *const Decoded) f64 {
        if (self.pcm.len == 0) return 0;
        var acc: f64 = 0;
        for (self.pcm) |s| acc += @as(f64, s) * @as(f64, s);
        return @sqrt(acc / @as(f64, @floatFromInt(self.pcm.len)));
    }
};

pub const DecodeError = error{ OpenFailed, OutOfMemory };

/// Decode a complete Ogg Vorbis stream (one interval's accumulated bytes).
pub fn decodeMemory(alloc: std.mem.Allocator, ogg: []const u8) DecodeError!Decoded {
    var err: c_int = 0;
    const v = stb_vorbis_open_memory(ogg.ptr, @intCast(ogg.len), &err, null) orelse
        return error.OpenFailed;
    defer stb_vorbis_close(v);
    const info = stb_vorbis_get_info(v);

    var out: std.ArrayList(f32) = .empty;
    errdefer out.deinit(alloc);

    var chans: c_int = 0;
    var outputs: [*][*]f32 = undefined;
    while (true) {
        const n = stb_vorbis_get_frame_float(v, &chans, &outputs);
        if (n == 0) break;
        const ch: usize = @intCast(chans);
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) {
            var k: usize = 0;
            while (k < ch) : (k += 1) {
                try out.append(alloc, outputs[k][i]);
            }
        }
    }
    return .{
        .alloc = alloc,
        .srate = @intCast(info.sample_rate),
        .channels = @intCast(info.channels),
        .pcm = try out.toOwnedSlice(alloc),
    };
}

// ---- encoder -----------------------------------------------------------------

/// One mono Vorbis encoder per local channel per interval — mirrors the
/// reference client (fresh stream + headers per interval, random serial).
pub const Encoder = struct {
    alloc: std.mem.Allocator,
    vi: c.vorbis_info,
    vc: c.vorbis_comment,
    vd: c.vorbis_dsp_state,
    vb: c.vorbis_block,
    os: c.ogg_stream_state,
    inited: bool = false,

    pub fn create(alloc: std.mem.Allocator, srate: c_int, quality: f32, serial: u32) EncodeError!*Encoder {
        const self = alloc.create(Encoder) catch return error.OutOfMemory;
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .vi = std.mem.zeroes(c.vorbis_info),
            .vc = std.mem.zeroes(c.vorbis_comment),
            .vd = std.mem.zeroes(c.vorbis_dsp_state),
            .vb = std.mem.zeroes(c.vorbis_block),
            .os = std.mem.zeroes(c.ogg_stream_state),
        };

        c.vorbis_info_init(&self.vi);
        if (c.vorbis_encode_init_vbr(&self.vi, 1, srate, quality) != 0)
            return error.InitFailed;
        c.vorbis_comment_init(&self.vc);
        c.vorbis_comment_add_tag(&self.vc, "ENCODER", "zclient");
        if (c.vorbis_analysis_init(&self.vd, &self.vi) != 0) return error.InitFailed;
        if (c.vorbis_block_init(&self.vd, &self.vb) != 0) return error.InitFailed;
        if (c.ogg_stream_init(&self.os, @intCast(serial & 0x7FFFFFFF)) != 0) return error.InitFailed;
        self.inited = true;
        return self;
    }

    pub fn destroy(self: *Encoder) void {
        if (self.inited) {
            _ = c.vorbis_dsp_clear(&self.vd);
            _ = c.vorbis_block_clear(&self.vb);
            _ = c.vorbis_comment_clear(&self.vc);
            _ = c.vorbis_info_clear(&self.vi);
            _ = c.ogg_stream_clear(&self.os);
        }
        self.alloc.destroy(self);
    }

    fn takePages(self: *Encoder, use_flush: bool, out: *std.ArrayList(u8)) !void {
        var og: c.ogg_page = undefined;
        while (true) {
            const got = if (use_flush) c.ogg_stream_flush(&self.os, &og) else c.ogg_stream_pageout(&self.os, &og);
            if (got != 1) break;
            try out.appendSlice(self.alloc, og.header[0..@intCast(og.header_len)]);
            try out.appendSlice(self.alloc, og.body[0..@intCast(og.body_len)]);
        }
    }

    fn drainBlocks(self: *Encoder, out: *std.ArrayList(u8)) !void {
        var op: c.ogg_packet = undefined;
        while (c.vorbis_analysis_blockout(&self.vd, &self.vb) == 1) {
            _ = c.vorbis_analysis(&self.vb, null);
            _ = c.vorbis_bitrate_addblock(&self.vb);
            while (c.vorbis_bitrate_flushpacket(&self.vd, &op) == 1) {
                _ = c.ogg_stream_packetin(&self.os, &op);
                try self.takePages(false, out);
            }
        }
    }

    /// Emit the 3 Vorbis header pages (id/comment/setup) into `out`.
    pub fn writeHeaders(self: *Encoder, out: *std.ArrayList(u8)) !void {
        var h_ident: c.ogg_packet = undefined;
        var h_comm: c.ogg_packet = undefined;
        var h_code: c.ogg_packet = undefined;
        _ = c.vorbis_analysis_headerout(&self.vd, &self.vc, &h_ident, &h_comm, &h_code);
        _ = c.ogg_stream_packetin(&self.os, &h_ident);
        _ = c.ogg_stream_packetin(&self.os, &h_comm);
        _ = c.ogg_stream_packetin(&self.os, &h_code);
        try self.takePages(true, out);
    }

    /// Encode `samples` (one mono channel) into `out` as Ogg page bytes.
    pub fn encode(self: *Encoder, samples: []const f32, out: *std.ArrayList(u8)) !void {
        if (samples.len == 0) return;
        const buf = c.vorbis_analysis_buffer(&self.vd, @intCast(samples.len));
        @memcpy(buf[0][0..samples.len], samples);
        _ = c.vorbis_analysis_wrote(&self.vd, @intCast(samples.len));
        try self.drainBlocks(out);
    }

    /// Flush encoder state; emits remaining pages including the EOS page.
    pub fn flush(self: *Encoder, out: *std.ArrayList(u8)) !void {
        _ = c.vorbis_analysis_wrote(&self.vd, 0);
        try self.drainBlocks(out);
        try self.takePages(true, out);
    }
};

// ==================================================================================
// tests
// ==================================================================================

const testing = std.testing;

test "vorbis encode -> decode roundtrip, non-silent" {
    const alloc = testing.allocator;
    const srate = 48000;
    const nsamples = 48000; // 1 second

    const enc = try Encoder.create(alloc, srate, 0.0, 12345);
    defer enc.destroy();

    var ogg: std.ArrayList(u8) = .empty;
    defer ogg.deinit(alloc);
    try enc.writeHeaders(&ogg);

    // 440 Hz sine at 0.5 amplitude, encoded in 960-sample blocks
    var block: [960]f32 = undefined;
    var i: usize = 0;
    while (i < nsamples) : (i += block.len) {
        for (&block, 0..) |*s, k| {
            const t = @as(f32, @floatFromInt(i + k)) / @as(f32, srate);
            s.* = 0.5 * @sin(2.0 * std.math.pi * 440.0 * t);
        }
        try enc.encode(&block, &ogg);
    }
    try enc.flush(&ogg);

    // the stream must start with an OggS capture pattern
    try testing.expect(ogg.items.len > 1000);
    try testing.expectEqualSlices(u8, "OggS", ogg.items[0..4]);

    var dec = try decodeMemory(alloc, ogg.items);
    defer dec.deinit();
    try testing.expectEqual(@as(u32, srate), dec.srate);
    try testing.expectEqual(@as(u32, 1), dec.channels);
    // decoded ~1s of audio; allow vorbis padding slack
    try testing.expect(dec.frames() > nsamples - 4800);
    // real signal energy: 0.5-amp sine -> rms ~= 0.3535
    const r = dec.rms();
    try testing.expect(r > 0.3);
}
