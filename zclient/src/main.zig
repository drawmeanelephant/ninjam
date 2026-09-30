//! zclient — from-scratch NINJAM client (see docs/PROTOCOL.md).
//!
//! Commands:
//!   zclient join --host 127.0.0.1:2049 --user alice --pass secret [options]
//!   zclient check-wav <file.wav> [--min-rms 0.001]

const std = @import("std");
const session = @import("session.zig");
const wavmod = @import("wav.zig");

fn printUsage(io: std.Io) void {
    const usage =
        \\usage:
        \\  zclient join --host 127.0.0.1[:port] --user NAME --pass PASS [options]
        \\    --srate N          engine sample rate (default 48000)
        \\    --channel NAME     local channel name (repeatable)
        \\    --source tone:FREQ:AMP | silence    local audio source (default tone:440:0.5)
        \\    --duration S       seconds to run (default 20)
        \\    --out-dir DIR      directory for decoded peer WAVs (default dump)
        \\    --transcript FILE  transcript log path (default <out-dir>/transcript.log)
        \\    --live             capture the local device and play the decoded
        \\                       peer mix through it (Phase B)
        \\    --chat TEXT        send a public MSG after joining
        \\    --chat-delay S     seconds before the MSG (default 1.5)
        \\    --live-period N    device period in frames (default 480 = 10 ms)
        \\    --audio-device ID  miniaudio device id (default: system default)
        \\    --play-wav FILE    dump the post-mix signal handed to the device
        \\  zclient check-wav FILE [--min-rms R]   analyze a WAV; exit 1 if rms < R
        \\
    ;
    std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
}

fn parseInto(comptime T: type, s: []const u8) !T {
    return std.fmt.parseInt(T, s, 10);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try std.process.Args.toSlice(init.minimal.args, arena);

    if (args.len < 2) {
        printUsage(io);
        std.process.exit(2);
    }

    if (std.mem.eql(u8, args[1], "check-wav")) {
        return cmdCheckWav(io, args[2..]);
    } else if (std.mem.eql(u8, args[1], "join")) {
        return cmdJoin(io, gpa, arena, args[2..]);
    } else if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "help")) {
        printUsage(io);
        return;
    }
    printUsage(io);
    std.process.exit(2);
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: " ++ fmt ++ "\n", args) catch "error\n";
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.process.exit(1);
}

fn cmdJoin(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, argv: []const []const u8) !void {
    var opts = session.Options{};
    var channels: std.ArrayList([]const u8) = .empty;
    defer channels.deinit(gpa);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const next: ?[]const u8 = if (i + 1 < argv.len) argv[i + 1] else null;
        if (std.mem.eql(u8, a, "--host")) {
            const v = next orelse fail(io, "--host needs a value", .{});
            if (std.mem.indexOfScalar(u8, v, ':')) |colon| {
                opts.host = v[0..colon];
                opts.port = parseInto(u16, v[colon + 1 ..]) catch fail(io, "bad port in --host", .{});
            } else {
                opts.host = v;
            }
            i += 1;
        } else if (std.mem.eql(u8, a, "--user")) {
            opts.user = next orelse fail(io, "--user needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--pass")) {
            opts.pass = next orelse fail(io, "--pass needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--srate")) {
            opts.srate = parseInto(u32, next orelse fail(io, "--srate needs a value", .{})) catch fail(io, "bad --srate", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--channel")) {
            const v = next orelse fail(io, "--channel needs a value", .{});
            channels.append(gpa, v) catch {};
            i += 1;
        } else if (std.mem.eql(u8, a, "--source")) {
            const v = next orelse fail(io, "--source needs a value", .{});
            if (std.mem.eql(u8, v, "silence")) {
                opts.source = .silence;
            } else if (std.mem.startsWith(u8, v, "tone:")) {
                var it = std.mem.splitScalar(u8, v[5..], ':');
                const freq = it.next() orelse fail(io, "bad --source", .{});
                const amp = it.next() orelse fail(io, "bad --source", .{});
                const f = std.fmt.parseFloat(f32, freq) catch fail(io, "bad tone freq", .{});
                const ampv = std.fmt.parseFloat(f32, amp) catch fail(io, "bad tone amp", .{});
                opts.source = .{ .tone = .{ .freq = f, .amp = ampv } };
            } else fail(io, "unknown --source '{s}'", .{v});
            i += 1;
        } else if (std.mem.eql(u8, a, "--duration")) {
            const secs = std.fmt.parseFloat(f64, next orelse fail(io, "--duration needs a value", .{})) catch fail(io, "bad --duration", .{});
            opts.duration_ms = @intFromFloat(secs * 1000.0);
            i += 1;
        } else if (std.mem.eql(u8, a, "--out-dir")) {
            opts.out_dir = next orelse fail(io, "--out-dir needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--transcript")) {
            opts.transcript_path = next orelse fail(io, "--transcript needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--live")) {
            opts.live = true;
        } else if (std.mem.eql(u8, a, "--chat")) {
            opts.chat = next orelse fail(io, "--chat needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--chat-delay")) {
            const secs = std.fmt.parseFloat(f64, next orelse fail(io, "--chat-delay needs a value", .{})) catch fail(io, "bad --chat-delay", .{});
            opts.chat_delay_ms = @intFromFloat(secs * 1000.0);
            i += 1;
        } else if (std.mem.eql(u8, a, "--live-period")) {
            opts.live_period = parseInto(u32, next orelse fail(io, "--live-period needs a value", .{})) catch fail(io, "bad --live-period", .{});
        } else if (std.mem.eql(u8, a, "--audio-device")) {
            opts.live_device = next orelse fail(io, "--audio-device needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--play-wav")) {
            opts.play_wav_path = next orelse fail(io, "--play-wav needs a value", .{});
            i += 1;
        } else {
            fail(io, "unknown option '{s}'", .{a});
        }
    }
    if (channels.items.len == 0) channels.append(gpa, "zclient") catch {};
    opts.channel_names = channels.items;
    if (opts.transcript_path == null) {
        opts.transcript_path = try std.fmt.allocPrint(arena, "{s}/transcript.log", .{opts.out_dir});
    }

    var s = session.Session.init(gpa, io, opts) catch |e| fail(io, "init failed: {s}", .{@errorName(e)});
    defer s.deinit();

    const stats = s.run() catch s.stats;

    // machine-readable summary for the demo scripts
    var out_buf: [4096]u8 = undefined;
    var n: usize = 0;
    const w = out_buf[0..];
    n += (std.fmt.bufPrint(w[n..], "RESULT ok={} err=\"{s}\"", .{ stats.ok, stats.failText() }) catch return).len;
    n += (std.fmt.bufPrint(w[n..], " msgs_sent={d} msgs_recv={d} bytes_sent={d} bytes_recv={d}", .{ stats.msgs_sent, stats.msgs_recv, stats.bytes_sent, stats.bytes_recv }) catch return).len;
    n += (std.fmt.bufPrint(w[n..], " intervals_uploaded={d} upload_channels={d} upload_chunks={d} upload_bytes={d}", .{ stats.intervals_uploaded, stats.upload_channels, stats.upload_chunks, stats.upload_bytes }) catch return).len;
    n += (std.fmt.bufPrint(w[n..], " intervals_downloaded={d} download_bytes={d} samples_decoded={d}", .{ stats.intervals_downloaded, stats.download_bytes, stats.samples_decoded }) catch return).len;
    n += (std.fmt.bufPrint(w[n..], " chat_sent={d} chat_received={d} wav_count={d} wav_rms_avg={d:.6}", .{ stats.chat_sent, stats.chat_received, stats.wav_count, if (stats.wav_count > 0) stats.wav_rms_sum / @as(f64, @floatFromInt(stats.wav_count)) else 0.0 }) catch return).len;
    n += (std.fmt.bufPrint(w[n..], " live={} device=\"{s}\" dev_srate={d}", .{ stats.live, stats.deviceName(), stats.device_srate }) catch return).len;
    n += (std.fmt.bufPrint(w[n..], " capture_frames={d} capture_starved={d} capture_rms={d:.6} capture_peak={d:.6}", .{ stats.capture_frames, stats.capture_zero_frames, session.Stats.rms(stats.capture_frames, stats.capture_energy), stats.capture_peak }) catch return).len;
    n += (std.fmt.bufPrint(w[n..], " playback_frames={d} playback_rms={d:.6} playback_peak={d:.6}", .{ stats.playback_frames, session.Stats.rms(stats.playback_frames, stats.playback_energy), stats.playback_peak }) catch return).len;
    n += (std.fmt.bufPrint(w[n..], " audio_underruns={d} audio_overruns={d}", .{ stats.rx_underruns, stats.rx_overruns }) catch return).len;
    n += (std.fmt.bufPrint(w[n..], "\n", .{}) catch return).len;
    std.Io.File.stdout().writeStreamingAll(io, w[0..n]) catch {};

    if (!stats.ok) std.process.exit(1);
}

fn cmdCheckWav(io: std.Io, argv: []const []const u8) !void {
    var path: ?[]const u8 = null;
    var min_rms: f64 = 0.001;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--min-rms")) {
            i += 1;
            if (i >= argv.len) fail(io, "--min-rms needs a value", .{});
            min_rms = std.fmt.parseFloat(f64, argv[i]) catch fail(io, "bad --min-rms", .{});
        } else {
            path = a;
        }
    }
    const p = path orelse fail(io, "check-wav needs a file path", .{});
    const a = wavmod.analyzeWavFile(io, p) catch fail(io, "cannot analyze '{s}'", .{p});
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "WAV {s} frames={d} srate={d} ch={d} rms={d:.6} peak={d:.6} pass={}\n", .{
        p, a.frames, a.srate, a.channels, a.rms, a.peak, a.rms >= min_rms,
    }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
    if (a.rms < min_rms) {
        var ebuf: [128]u8 = undefined;
        const emsg = std.fmt.bufPrint(&ebuf, "FAIL: rms {d:.6} < {d:.6}\n", .{ a.rms, min_rms }) catch "FAIL\n";
        std.Io.File.stderr().writeStreamingAll(io, emsg) catch {};
        std.process.exit(1);
    }
}
