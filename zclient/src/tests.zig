//! Test root: pulls in all modules so `zig build test` compiles + runs them.

const std = @import("std");

test {
    std.testing.refAllDecls(@import("buf.zig"));
    std.testing.refAllDecls(@import("net.zig"));
    std.testing.refAllDecls(@import("proto.zig"));
    std.testing.refAllDecls(@import("auth.zig"));
    std.testing.refAllDecls(@import("wav.zig"));
    std.testing.refAllDecls(@import("vorbis.zig"));
    std.testing.refAllDecls(@import("session.zig"));
    std.testing.refAllDecls(@import("main.zig"));
    std.testing.refAllDecls(@import("log.zig"));
    // audio.zig owns the live-audio ring/resampler tests; imported (not
    // refAllDecls) so `zig build test -Dlive=false` still links without miniaudio
    _ = @import("audio.zig");
}
