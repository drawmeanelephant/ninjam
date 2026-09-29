//! Timestamped transcript logger: every line goes to stderr (unless quiet)
//! and optionally to a transcript file. Relative seconds since start.

const std = @import("std");
const clock = @import("clock.zig");

pub const Log = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    file: ?std.Io.File = null,
    start_ns: i128 = 0,
    quiet: bool = false,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, path: ?[]const u8, quiet: bool) Log {
        var l = Log{ .alloc = alloc, .io = io, .quiet = quiet };
        l.start_ns = clock.nowNs(io);
        if (path) |p| {
            l.file = std.Io.Dir.cwd().createFile(io, p, .{}) catch null;
        }
        return l;
    }

    pub fn deinit(self: *Log) void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
    }

    pub fn line(self: *Log, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const elapsed_s: f64 = @as(f64, @floatFromInt(clock.nowNs(self.io) - self.start_ns)) / 1e9;
        const body = std.fmt.bufPrint(&buf, "[{d: >9.3}] " ++ fmt ++ "\n", .{elapsed_s} ++ args) catch return;
        if (!self.quiet) {
            std.Io.File.stderr().writeStreamingAll(self.io, body) catch {};
        }
        if (self.file) |f| {
            f.writeStreamingAll(self.io, body) catch {};
        }
    }
};
