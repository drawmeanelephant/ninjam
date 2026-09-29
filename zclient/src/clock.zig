//! Clock helpers over the std.Io clock interface.

const std = @import("std");

/// Monotonic nanoseconds (does not include suspension time).
pub fn nowNs(io: std.Io) i128 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

/// Wall-clock milliseconds (unix epoch).
pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}
