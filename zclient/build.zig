const std = @import("std");
const builtin = @import("builtin");

const c_flags = [_][]const u8{
    "-std=gnu99",
    // libvorbis relies on wrapping shift semantics (psy.c); zig cc's UBSan
    // turns that into a runtime panic, so opt the vendored C out of UBSan.
    "-fno-sanitize=undefined",
};

const c_sources = [_][]const u8{
    "libogg/src/bitwise.c",
    "libogg/src/framing.c",
    "libvorbis/lib/analysis.c",
    "libvorbis/lib/bitrate.c",
    "libvorbis/lib/block.c",
    "libvorbis/lib/codebook.c",
    "libvorbis/lib/envelope.c",
    "libvorbis/lib/floor0.c",
    "libvorbis/lib/floor1.c",
    "libvorbis/lib/info.c",
    "libvorbis/lib/lookup.c",
    "libvorbis/lib/lpc.c",
    "libvorbis/lib/lsp.c",
    "libvorbis/lib/mapping0.c",
    "libvorbis/lib/mdct.c",
    "libvorbis/lib/psy.c",
    "libvorbis/lib/registry.c",
    "libvorbis/lib/res0.c",
    "libvorbis/lib/sharedbook.c",
    "libvorbis/lib/smallft.c",
    "libvorbis/lib/synthesis.c",
    "libvorbis/lib/vorbisenc.c",
    "libvorbis/lib/window.c",
    "stb_vorbis_impl.c",
};

/// Phase B live audio. miniaudio.h is not translate-c clean, so it lives in a
/// single C TU behind the shim in vendor/miniaudio_impl.c; Zig declares the
/// handful of entry points in src/audio.zig.
const miniaudio_source = [_][]const u8{"miniaudio_impl.c"};

/// Apple frameworks miniaudio's CoreAudio backend needs (playback + capture).
/// Nothing else: the resulting binary links only libSystem + these.
const apple_audio_frameworks = [_][]const u8{
    "CoreAudio",
    "AudioToolbox",
    "AudioUnit",
    "CoreFoundation",
    "CoreServices",
};

fn addVendored(mod: *std.Build.Module, live: bool) void {
    mod.link_libc = true;
    mod.addIncludePath(b_path_vendor);
    mod.addIncludePath(vendor_libogg_include);
    mod.addIncludePath(vendor_libvorbis_include);
    mod.addIncludePath(vendor_libvorbis_lib);
    mod.addCSourceFiles(.{ .root = vendor_root, .files = &c_sources, .flags = &c_flags });
    if (live) {
        mod.addCSourceFiles(.{ .root = vendor_root, .files = &miniaudio_source, .flags = &c_flags });
        if (builtin.target.os.tag == .macos) {
            for (apple_audio_frameworks) |fw| mod.linkFramework(fw, .{});
        } else if (builtin.target.os.tag == .linux) {
            mod.linkSystemLibrary("asound", .{});
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("m", .{});
        }
    }
    mod.addOptions("build_options", build_options);
}

// resolved lazily in build() below; kept as globals for addVendored
var vendor_root: std.Build.LazyPath = undefined;
var b_path_vendor: std.Build.LazyPath = undefined;
var vendor_libogg_include: std.Build.LazyPath = undefined;
var vendor_libvorbis_include: std.Build.LazyPath = undefined;
var vendor_libvorbis_lib: std.Build.LazyPath = undefined;
var build_options: *std.Build.Step.Options = undefined;

pub fn build(b: *std.Build) void {
    vendor_root = b.path("vendor");
    b_path_vendor = b.path("vendor");
    vendor_libogg_include = b.path("vendor/libogg/include");
    vendor_libvorbis_include = b.path("vendor/libvorbis/include");
    vendor_libvorbis_lib = b.path("vendor/libvorbis/lib");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Live audio defaults on for macOS (CoreAudio) and off everywhere else,
    // so the Linux static cross-build stays free of ALSA headers.
    const live = b.option(bool, "live", "Phase B live audio via miniaudio (default: on when targeting macOS)") orelse
        (target.result.os.tag == .macos);
    build_options = b.addOptions();
    build_options.addOption(bool, "live", live);
    const live_step = b.step("live", "Report live-audio build state");
    live_step.dependOn(&build_options.step);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addVendored(exe_mod, live);
    const exe = b.addExecutable(.{ .name = "zclient", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zclient");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    addVendored(test_mod, live);
    const unit_tests = b.addTest(.{ .name = "zclient-tests", .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
