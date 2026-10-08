//! Small byte-buffer primitives shared by the protocol layer.
//! Hand-rolled to avoid depending on std container API churn.

const std = @import("std");

/// Growable heap byte buffer.
pub const Buf = struct {
    alloc: std.mem.Allocator,
    bytes: []u8 = &.{},
    len: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Buf {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Buf) void {
        if (self.bytes.len > 0) self.alloc.free(self.bytes);
        self.bytes = &.{};
        self.len = 0;
    }

    pub fn clear(self: *Buf) void {
        self.len = 0;
    }

    pub fn items(self: *const Buf) []u8 {
        return self.bytes[0..self.len];
    }

    pub fn ensureCapacity(self: *Buf, extra: usize) !void {
        const need = self.len + extra;
        if (need <= self.bytes.len) return;
        var cap: usize = if (self.bytes.len == 0) 256 else self.bytes.len;
        while (cap < need) cap *= 2;
        if (self.bytes.len == 0) {
            self.bytes = try self.alloc.alloc(u8, cap);
        } else {
            self.bytes = try self.alloc.realloc(self.bytes, cap);
        }
    }

    pub fn add(self: *Buf, data: []const u8) !void {
        try self.ensureCapacity(data.len);
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn addByte(self: *Buf, b: u8) !void {
        try self.ensureCapacity(1);
        self.bytes[self.len] = b;
        self.len += 1;
    }

    pub fn addU16le(self: *Buf, v: u16) !void {
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(u16, &tmp, v, .little);
        try self.add(&tmp);
    }

    pub fn addU32le(self: *Buf, v: u32) !void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        try self.add(&tmp);
    }

    pub fn addI16le(self: *Buf, v: i16) !void {
        try self.addU16le(@bitCast(v));
    }

    /// NUL-terminated string, terminator included (NINJAM string encoding).
    pub fn addNulstr(self: *Buf, s: []const u8) !void {
        try self.add(s);
        try self.addByte(0);
    }
};

/// Fixed-capacity stack buffer for building message payloads (max 16384).
pub const Fixed = struct {
    bytes: [16384]u8 = undefined,
    len: usize = 0,

    pub const Error = error{Overflow};

    pub fn clear(self: *Fixed) void {
        self.len = 0;
    }

    pub fn slice(self: *const Fixed) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn add(self: *Fixed, data: []const u8) Error!void {
        if (self.len + data.len > self.bytes.len) return error.Overflow;
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn addByte(self: *Fixed, b: u8) Error!void {
        return self.add(&[1]u8{b});
    }

    pub fn addU16le(self: *Fixed, v: u16) Error!void {
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(u16, &tmp, v, .little);
        return self.add(&tmp);
    }

    pub fn addU32le(self: *Fixed, v: u32) Error!void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        return self.add(&tmp);
    }

    pub fn addI16le(self: *Fixed, v: i16) Error!void {
        return self.addU16le(@bitCast(v));
    }

    pub fn addI8(self: *Fixed, v: i8) Error!void {
        return self.add(&[1]u8{@bitCast(v)});
    }

    pub fn addNulstr(self: *Fixed, s: []const u8) Error!void {
        try self.add(s);
        try self.addByte(0);
    }
};

/// Cursor-based reader over a payload slice. All multi-byte reads are LE.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }

    pub fn take(self: *Reader, n: usize) error{Truncated}![]const u8 {
        if (self.remaining() < n) return error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    pub fn readByte(self: *Reader) error{Truncated}!u8 {
        const s = try self.take(1);
        return s[0];
    }

    pub fn readU16le(self: *Reader) error{Truncated}!u16 {
        const s = try self.take(2);
        return std.mem.readInt(u16, s[0..2], .little);
    }

    pub fn readU32le(self: *Reader) error{Truncated}!u32 {
        const s = try self.take(4);
        return std.mem.readInt(u32, s[0..4], .little);
    }

    pub fn readI16le(self: *Reader) error{Truncated}!i16 {
        return @bitCast(try self.readU16le());
    }

    pub fn readI8(self: *Reader) error{Truncated}!i8 {
        return @bitCast(try self.readByte());
    }

    /// NUL-terminated string; the returned slice excludes the NUL.
    pub fn readNulstr(self: *Reader) error{Truncated}![]const u8 {
        const start = self.pos;
        while (self.pos < self.data.len) : (self.pos += 1) {
            if (self.data[self.pos] == 0) {
                const s = self.data[start..self.pos];
                self.pos += 1;
                return s;
            }
        }
        return error.Truncated;
    }
};

test "buf roundtrip" {
    var b = Buf.init(std.testing.allocator);
    defer b.deinit();
    try b.addU32le(0xDEADBEEF);
    try b.addNulstr("hello");
    try b.addByte(0x42);
    var r = Reader.init(b.items());
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try r.readU32le());
    try std.testing.expectEqualStrings("hello", try r.readNulstr());
    try std.testing.expectEqual(@as(u8, 0x42), try r.readByte());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "fixed overflow" {
    var f = Fixed{};
    try std.testing.expectError(error.Overflow, f.add(&@as([16385]u8, @splat(0))));
    try f.addU16le(0x0102);
    try std.testing.expectEqualSlices(u8, &[2]u8{ 2, 1 }, f.slice());
}
