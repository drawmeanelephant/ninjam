//! Minimal WAV writer + signal-energy analysis.
//! Dumps are s16le PCM; the writer buffers in memory and writes once at close.

const std = @import("std");
const bufmod = @import("buf.zig");

pub const WavWriter = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    file: ?std.Io.File = null,
    pcm: bufmod.Buf,
    srate: u32,
    channels: u16,
    frames: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, srate: u32, channels: u16) WavWriter {
        return .{ .alloc = alloc, .io = io, .pcm = bufmod.Buf.init(alloc), .srate = srate, .channels = channels };
    }

    pub fn deinit(self: *WavWriter) void {
        self.pcm.deinit();
        if (self.file) |f| f.close(self.io);
        self.file = null;
    }

    pub fn open(self: *WavWriter, path: []const u8) !void {
        if (self.file != null) return error.AlreadyOpen;
        self.file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
    }

    /// Append interleaved f32 samples (frames * channels), converting to s16.
    pub fn writeFloats(self: *WavWriter, interleaved: []const f32) !void {
        try self.pcm.ensureCapacity(interleaved.len * 2);
        for (interleaved) |s| {
            const clamped = std.math.clamp(s, -1.0, 1.0);
            const v: i16 = @intFromFloat(clamped * 32767.0);
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(i16, &tmp, v, .little);
            try self.pcm.add(&tmp);
        }
        self.frames += interleaved.len / self.channels;
    }

    pub fn close(self: *WavWriter) !void {
        const f = self.file orelse return error.NotOpen;
        self.file = null;
        defer f.close(self.io);
        const data_len: u32 = @intCast(self.pcm.len);
        var hdr: [44]u8 = undefined;
        writeHeader(&hdr, self.srate, self.channels, data_len);
        try f.writeStreamingAll(self.io, &hdr);
        if (self.pcm.len > 0) try f.writeStreamingAll(self.io, self.pcm.items());
    }
};

pub fn writeHeader(hdr: *[44]u8, srate: u32, channels: u16, data_len: u32) void {
    const byte_rate: u32 = srate * @as(u32, channels) * 2;
    const block_align: u16 = channels * 2;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], 36 + data_len, .little);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, hdr[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, hdr[22..24], channels, .little);
    std.mem.writeInt(u32, hdr[24..28], srate, .little);
    std.mem.writeInt(u32, hdr[28..32], byte_rate, .little);
    std.mem.writeInt(u16, hdr[32..34], block_align, .little);
    std.mem.writeInt(u16, hdr[34..36], 16, .little); // bits per sample
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], data_len, .little);
}

pub const Analysis = struct {
    frames: u64,
    channels: u16,
    srate: u32,
    rms: f64,
    peak: f64,
};

/// Walk a RIFF file, find the fmt+data chunks, analyze signal energy.
pub fn analyzeWavFile(io: std.Io, path: []const u8) !Analysis {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const size = try f.length(io);
    if (size < 44) return error.BadWav;
    var data: []u8 = try std.heap.page_allocator.alloc(u8, @intCast(size));
    defer std.heap.page_allocator.free(data);
    const got = try f.readPositionalAll(io, data, 0);
    return analyzeWavBytes(data[0..got]);
}

pub fn analyzeWavBytes(data: []const u8) !Analysis {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE"))
        return error.BadWav;
    var off: usize = 12;
    var srate: u32 = 0;
    var channels: u16 = 0;
    var fmt_found = false;
    var pcm: []const u8 = "";
    while (off + 8 <= data.len) {
        const id = data[off .. off + 4];
        const csize = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
        const body = data[off + 8 .. @min(data.len, off + 8 + csize)];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.BadWav;
            const audio_fmt = std.mem.readInt(u16, body[0..2], .little);
            if (audio_fmt != 1) return error.BadWav; // PCM only
            channels = std.mem.readInt(u16, body[2..4], .little);
            srate = std.mem.readInt(u32, body[4..8], .little);
            fmt_found = true;
        } else if (std.mem.eql(u8, id, "data")) {
            pcm = body;
        }
        off = off + 8 + csize + (csize & 1); // chunks are word-aligned
    }
    if (!fmt_found or pcm.len == 0 or channels == 0) return error.BadWav;

    var acc: f64 = 0;
    var peak: f64 = 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i + 2 <= pcm.len) : (i += 2) {
        const v = std.mem.readInt(i16, pcm[i..][0..2], .little);
        const s: f64 = @as(f64, @floatFromInt(v)) / 32768.0;
        acc += s * s;
        const a = @abs(s);
        if (a > peak) peak = a;
        count += 1;
    }
    const rms: f64 = if (count == 0) 0 else @sqrt(acc / @as(f64, @floatFromInt(count)));
    return .{
        .frames = count / channels,
        .channels = channels,
        .srate = srate,
        .rms = rms,
        .peak = peak,
    };
}

test "wav write/analyze roundtrip non-silence" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var w = WavWriter.init(alloc, io, 48000, 1);
    defer w.deinit();
    var samples: [4800]f32 = undefined;
    for (&samples, 0..) |*s, i| {
        s.* = 0.5 * @sin(2.0 * std.math.pi * 440.0 * @as(f32, @floatFromInt(i)) / 48000.0);
    }
    try w.writeFloats(&samples);
    var tmp: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&tmp, "/tmp/zclient-test-{d}.wav", .{std.c.getpid()});
    try w.open(path);
    try w.close();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const a = try analyzeWavFile(io, path);
    try std.testing.expectEqual(@as(u32, 48000), a.srate);
    try std.testing.expectEqual(@as(u64, 4800), a.frames);
    // a 0.5-amp sine has rms ~ 0.3535; assert well above silence
    try std.testing.expect(a.rms > 0.3);
    try std.testing.expect(a.peak > 0.45);
}
