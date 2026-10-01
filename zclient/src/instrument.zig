//! Reusable interval identity, timing, backoff, and deterministic upload helpers.

const std = @import("std");
const testing = std.testing;

/// Filename for one interval's payload dump: `<dump_dir>/interval_NNNN.ogg`,
/// keyed by the monotonic sequence so a grid re-anchor can never overwrite an
/// earlier interval's bytes (the determinism evidence the demo diffs).
pub fn payloadDumpName(
    alloc: std.mem.Allocator,
    dump_dir: []const u8,
    interval_seq: u64,
) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/interval_{d:0>4}.ogg", .{ dump_dir, interval_seq });
}

// ---- interval identity vs. grid position -----------------------------------

/// The two roles a NINJAM session's interval counter has to play, which used
/// to be conflated in one `interval_idx` field (#12).
///
/// `seq` is **identity**: monotonic for the life of the session, and the only
/// thing allowed to derive transport ids (guid + libvorbis serial), name a
/// payload dump, or count against `--intervals`. Before the split, a `0x02`
/// config change reset this counter to 0, which re-issued guids the server had
/// already seen carrying *different* payload bytes and silently overwrote
/// earlier `interval_NNNN.ogg` dumps.
///
/// `grid` is **position**: it drives the bar-pattern decision only. A config
/// change re-anchors the *timing* onto the new grid but leaves the bar counter
/// and the phrase cursor continuous, so the phrase is not cut. `reanchor` is
/// the explicit escape hatch for a grid that genuinely restarts (reconnect,
/// #24); it is safe only because identity does not depend on it.
pub const IntervalIndex = struct {
    /// monotonic per-session interval identity — guids, dumps, `--intervals`
    seq: u64 = 0,
    /// position in the current grid — bar pattern / broadcast decision
    grid: u64 = 0,

    /// Finish the current interval: identity and position advance together.
    pub fn complete(self: *IntervalIndex) void {
        self.seq += 1;
        self.grid += 1;
    }

    /// Move the grid position without disturbing interval identity, so guids
    /// stay unique and payload dumps keep their filenames.
    pub fn reanchor(self: *IntervalIndex, bar: u64) void {
        self.grid = bar;
    }
};

// ---- reconnect backoff (#24) -------------------------------------------------

/// How long to wait before reconnect dial attempt `attempt` (0-based), in ms.
///
/// Exponential from `start_ms`, hard-capped at `max_ms` — the delay is bounded
/// twice on purpose. Exponential alone would wait whole minutes by attempt 12,
/// which for an always-on room instrument is indistinguishable from being gone;
/// the cap keeps the instrument probing at a steady clip once the outage is
/// clearly not a blip. The budget of attempts itself lives in the session's
/// options; this function only prices each one.
///
/// Pure, so the bound is testable without a socket and mutable without a
/// network: deleting the clamp shows up as a unit failure, not as a CI runner
/// that happens to be slow. The early return inside the loop is also what makes
/// a large attempt count unrepresentable — without it, doubling `start_ms`
/// `u32`-many times overflows before the final `@min` could save it.
pub fn reconnectDelayMs(attempt: u32, start_ms: i64, max_ms: i64) i64 {
    var delay = @max(start_ms, 1);
    var i: u32 = 0;
    while (i < attempt) : (i += 1) {
        if (delay >= max_ms) return max_ms;
        delay *= 2;
    }
    return @min(delay, max_ms);
}

test "reconnect backoff: doubles from the start, clamps at the max, never overflows" {
    // attempt 0 is the first delay, not zero — a reconnect that waits 0 ms
    // would hammer a server that is likely down for a reason
    try std.testing.expectEqual(@as(i64, 500), reconnectDelayMs(0, 500, 8_000));
    try std.testing.expectEqual(@as(i64, 1_000), reconnectDelayMs(1, 500, 8_000));
    try std.testing.expectEqual(@as(i64, 2_000), reconnectDelayMs(2, 500, 8_000));
    // the clamp: attempt 4 and attempt 40 price the same, and a huge attempt
    // count cannot overflow the doubling on its way there
    try std.testing.expectEqual(@as(i64, 8_000), reconnectDelayMs(4, 500, 8_000));
    try std.testing.expectEqual(@as(i64, 8_000), reconnectDelayMs(40, 500, 8_000));
    try std.testing.expectEqual(@as(i64, 8_000), reconnectDelayMs(std.math.maxInt(u32), 500, 8_000));
    // a floor of 1 ms: start_ms = 0 is a test convenience, not a hammer
    try std.testing.expectEqual(@as(i64, 1), reconnectDelayMs(0, 0, 8_000));
    try std.testing.expectEqual(@as(i64, 4), reconnectDelayMs(2, 1, 4));
}

// ---- server-clock discipline (#13) -------------------------------------------

/// One bar's length in nanoseconds, straight from `bpi`/`bpm`.
///
/// Deliberately *not* `@divTrunc(samples_per_bar * 1e9 / srate)`, which is what
/// the session used before: that truncates twice (the sample count, then the
/// nanoseconds) and so loses up to a sample per bar. Measured at 48 kHz,
/// 5 bpi / 137 bpm the old form is 2 189 770 833 ns against this one's
/// 2 189 781 021 ns — 10.2 us short, every bar, forever. The session then kept
/// its own clock and the server kept its own and neither was wrong; they just
/// slid apart, which is precisely the drift #13 exists to stop measuring.
/// One division from the wire values has no such error.
pub fn intervalNsFor(bpm: u16, bpi: u16) i128 {
    return @divTrunc(@as(i128, bpi) * 60 * 1_000_000_000, @as(i128, bpm));
}

/// The session's bar grid, anchored to the server's.
///
/// Before #13 the grid was open loop: `interval_start_ns += interval_ns`, and
/// that was the whole of it. Nothing ever compared the local grid against
/// anything, so two things happened silently:
///
///  1. **Every bar stole its own audio budget.** The run loop's poll is up to
///     20 ms of granularity and `finalizeInterval` adds its own socket time, so
///     a bar's audio is finished *after* the bar's nominal end. The next
///     `interval_start_ns` is computed from the previous one anyway, so the
///     session starts every bar already behind — and `advanceAudio` pays it
///     back as one catch-up burst of generation.
///  2. **The debt compounded.** Nothing ever gave it back, so each stall was
///     inherited by the bar after it.
///
/// This is a deliberately small PLL: one number (how late did we cross the
/// boundary), one bounded correction, applied once per bar.
///
/// **On what drift actually is.** The local grid and the server's grid are not
/// really in disagreement: both advance by `interval_ns` and both start at the
/// `0x02` arrival, so the difference between them is a *constant* — the one-way
/// latency of the config message — and a constant nobody can measure from the
/// client side. It is also harmless, because the server re-times an upload on
/// arrival. So the correction here deliberately does **not** chase the server's
/// epoch. What it chases is *execution lag*: how far past its own nominal end
/// the local grid actually got. That is the quantity that accumulates, and
/// bounding it is what keeps the client from owing time it can never repay.
///
/// Both halves are bounded. A bar's length may be shortened or stretched by at
/// most `slewLimitNs` — 1% of the bar, and never more than
/// `max_slew_ns` absolute, because a stretch that is 1% of a ten-second bar is
/// 100 ms of tempo, which IS audible and must not be applied just because the
/// tempo is slow. The encode lead (#13, `encodeLeadSamples`) is bounded the same
/// way, in the other direction: it pulls the *end* of the bar's generation
/// forward so the final flush and its 0x84 chunk land inside the server's
/// window instead of on its trailing edge.
pub const ServerClock = struct {
    /// local monotonic time of the boundary the server's `0x02` was anchored to
    epoch_ns: i128 = 0,
    /// one bar in ns (`intervalNsFor`)
    interval_ns: i128 = 0,
    /// bars since the anchor; `epoch_ns + bars * interval_ns` is the grid
    bars: u64 = 0,
    /// absolute ceiling on a single bar's correction, ns
    max_slew_ns: i128 = 40 * std.time.ns_per_ms,
    /// the correction is also capped at `interval_ns / max_slew_div`
    max_slew_div: u32 = 100, // 1%

    // telemetry: a session's verdict on how well it kept time
    /// signed lag at the most recent boundary, ns (positive = late)
    drift_ns: i64 = 0,
    /// largest |lag| seen this session, ns
    max_abs_drift_ns: u64 = 0,
    /// bars where the correction was non-zero
    corrections: u64 = 0,
    /// sum of the corrections applied, ns
    total_correction_ns: i64 = 0,

    /// Anchor on a fresh server boundary (the `0x02` arrival).
    ///
    /// `bpm`/`bpi` must already be validated non-zero: `intervalNsFor`
    /// divides by `bpm`, and a zero bpm reaching it is the #41 panic again in a
    /// different function. The session's `onConfig` refuses that config before
    /// it ever gets here.
    pub fn anchor(self: *ServerClock, now_ns: i128, bpm: u16, bpi: u16) void {
        self.epoch_ns = now_ns;
        self.interval_ns = intervalNsFor(bpm, bpi);
        self.bars = 0;
    }

    /// The server-derived wall time of bar `n` from the anchor.
    pub fn boundaryNs(self: *const ServerClock, n: u64) i128 {
        return self.epoch_ns + @as(i128, @intCast(n)) * self.interval_ns;
    }

    /// Largest correction this clock will ever apply to one bar.
    ///
    /// The fraction is what makes a fast tempo safe (1% of a 200 ms bar is 2 ms,
    /// which cannot be heard) and the absolute cap is what makes a slow one
    /// safe (1% of a 10 s bar would be 100 ms, which can). Both bounds are
    /// needed; neither alone is.
    pub fn slewLimitNs(self: *const ServerClock) i128 {
        const fractional = @divTrunc(self.interval_ns, @as(i128, self.max_slew_div));
        return @max(0, @min(self.max_slew_ns, fractional));
    }

    /// Clamp a proposed correction into `[-limit, +limit]`.
    pub fn clampCorrection(self: *const ServerClock, want_ns: i128) i128 {
        const limit = self.slewLimitNs();
        return std.math.clamp(want_ns, -limit, limit);
    }

    /// How late (or early) the boundary crossing was, in ns.
    ///
    /// `now_ns` is when the session actually crossed the boundary and
    /// `local_start_ns` is when its own grid says that was. Positive means the
    /// bar finished late and the next one starts behind.
    pub fn measureDrift(self: *ServerClock, now_ns: i128, local_start_ns: i128) i128 {
        const nominal_end = local_start_ns + self.interval_ns;
        const drift = now_ns - nominal_end;
        self.drift_ns = @intCast(drift);
        const mag: u64 = @intCast(if (drift < 0) -drift else drift);
        if (mag > self.max_abs_drift_ns) self.max_abs_drift_ns = mag;
        return drift;
    }

    /// The `interval_start_ns` the next bar should use.
    ///
    /// Takes the un-corrected value the caller would have used and returns it
    /// plus a bounded nudge forward (or back) toward the wall clock. This is
    /// the *only* place a bar's length is allowed to differ from nominal, which
    /// is what makes "no audible jumps" checkable rather than aspirational: one
    /// bar moves by at most `slewLimitNs`, and no correction is ever larger
    /// than the lag that caused it, so the grid can never be yanked.
    ///
    /// Correcting toward `now_ns` rather than toward the server's epoch is
    /// deliberate; see the type's doc comment on what drift really is here.
    pub fn nextStartNs(self: *ServerClock, local_start_ns: i128, now_ns: i128) i128 {
        const nominal = local_start_ns + self.interval_ns;
        const drift = self.measureDrift(now_ns, local_start_ns);
        const correction = self.clampCorrection(drift);
        if (correction != 0) {
            self.corrections += 1;
            self.total_correction_ns += @intCast(correction);
        }
        self.bars += 1;
        return nominal + correction;
    }

    /// How many samples early the encoder should finish a bar, so the final
    /// flush and its last `0x84` chunk are already in flight when the boundary
    /// arrives instead of starting at it.
    ///
    /// This changes *when* a bar is generated, never *what*: the block size, the
    /// sample sequence and therefore the encoded bytes are identical either way,
    /// so the determinism evidence (#19, `demo/run_demo.sh`) is untouched.
    ///
    /// Bounded for the same reason the slew is: a lead is a window opened early,
    /// and opening it too far means generating audio for a bar the session may
    /// never get to upload.
    pub fn encodeLeadSamples(self: *const ServerClock, interval_len_samples: u64) u64 {
        if (self.interval_ns <= 0 or interval_len_samples == 0) return 0;
        const lead_ns = @min(self.slewLimitNs(), 50 * std.time.ns_per_ms);
        const per_sample = @divTrunc(self.interval_ns, @as(i128, @intCast(interval_len_samples)));
        if (per_sample <= 0) return 0;
        return @min(@as(u64, @intCast(@divTrunc(lead_ns, per_sample))), interval_len_samples);
    }
};

// ---- server-clock discipline tests (#13) -------------------------------------

test "one bar in ns comes from bpi/bpm directly, not from a truncated sample count" {
    // 48 kHz, 8 bpi, 100 bpm: 4.8 s, and both forms happen to agree exactly.
    try testing.expectEqual(@as(i128, 4_800_000_000), intervalNsFor(100, 8));

    // 48 kHz, 5 bpi, 137 bpm: this is where the old form lost time. The sample
    // count truncates (105109 of 105109.489) and the nanoseconds truncate again,
    // so the session's bar was 10.2 us short of the real one — every bar,
    // forever, with nothing measuring it.
    const exact = intervalNsFor(137, 5);
    const samples = @as(u64, 48000) * 5 * 60 / 137;
    const old = @divTrunc(@as(i128, @intCast(samples)) * 1_000_000_000, 48000);
    try testing.expectEqual(@as(i128, 2_189_781_021), exact);
    try testing.expectEqual(@as(i128, 2_189_770_833), old);
    try testing.expect(exact > old);
    // the gap is under one sample, which is the whole claim: the old form was
    // not catastrophically wrong, it was *systematically* wrong
    try testing.expect(exact - old < @divTrunc(1_000_000_000, 48000) + 1);
}

test "the slew limit is bounded twice: a fraction of the bar and an absolute cap" {
    // fast tempo: 1% of a 200 ms bar is 2 ms, and that is what applies
    var fast = ServerClock{};
    fast.anchor(0, 1200, 4); // 48000*4*60/1200 = 9600 samples = 200 ms
    try testing.expectEqual(@as(i128, 200_000_000), fast.interval_ns);
    try testing.expectEqual(@as(i128, 2_000_000), fast.slewLimitNs());

    // slow tempo: 1% of a 10 s bar would be 100 ms, which IS audible, so the
    // absolute cap has to take over. Without the second bound this test fails.
    var slow = ServerClock{};
    slow.anchor(0, 24, 4); // 4*60/24 = 10 s
    try testing.expectEqual(@as(i128, 10_000_000_000), slow.interval_ns);
    try testing.expectEqual(@as(i128, 40 * std.time.ns_per_ms), slow.slewLimitNs());
}

test "a bar is never stretched by more than the limit, however late it is (#13)" {
    var c = ServerClock{};
    c.anchor(0, 120, 4); // 2 s bars
    const limit = c.slewLimitNs();
    try testing.expectEqual(@as(i128, 20 * std.time.ns_per_ms), limit);

    // a boundary crossed 10 seconds late — a catastrophic stall
    const start: i128 = 0;
    const next = c.nextStartNs(start, 10 * std.time.ns_per_s);
    const moved = next - (start + c.interval_ns);
    try testing.expect(moved > 0);
    try testing.expectEqual(limit, moved); // clamped, exactly at the limit
}

test "a correction is never larger than the lag that caused it (#13: no overshoot)" {
    var c = ServerClock{};
    c.anchor(0, 120, 4);
    // 5 ms late: well inside the 20 ms limit, so the whole lag is given back
    const start: i128 = 0;
    const next = c.nextStartNs(start, c.interval_ns + 5 * std.time.ns_per_ms);
    try testing.expectEqual(@as(i128, 5 * std.time.ns_per_ms), next - (start + c.interval_ns));

    // early: the correction runs the other way, and is still bounded by the lag
    const early = c.nextStartNs(start, c.interval_ns - 3 * std.time.ns_per_ms);
    try testing.expectEqual(@as(i128, -3 * std.time.ns_per_ms), early - (start + c.interval_ns));
}

test "a session on time is never corrected (#13: zero drift means zero correction)" {
    var c = ServerClock{};
    c.anchor(1_000, 120, 4);
    var start: i128 = 1_000;
    // every bar crossed exactly on its nominal end
    for (0..8) |_| {
        const next = c.nextStartNs(start, start + c.interval_ns);
        try testing.expectEqual(start + c.interval_ns, next);
        start = next;
    }
    try testing.expectEqual(@as(u64, 0), c.corrections);
    try testing.expectEqual(@as(i64, 0), c.total_correction_ns);
    try testing.expectEqual(@as(u64, 0), c.max_abs_drift_ns);
}

test "the encode lead is a real, bounded margin and never eats the bar (#13)" {
    var c = ServerClock{};
    c.anchor(0, 120, 4); // 2 s bar, 96000 samples @48k
    const lead = c.encodeLeadSamples(96000);
    try testing.expect(lead > 0);
    // the lead shares the slew's bounds: 20 ms of a 2 s bar, which is 960 of
    // 96000 samples. It is the same 1% — opening the upload window early by the
    // same fraction the grid may be stretched by.
    try testing.expectEqual(@as(u64, 960), lead);
    // and it can never be the whole bar, whatever the tempo
    try testing.expect(lead < 96000);

    // an unanchored clock has no bar length and therefore no lead: generating
    // ahead of an interval that does not exist yet would be a lie
    var cold = ServerClock{};
    try testing.expectEqual(@as(u64, 0), cold.encodeLeadSamples(96000));
    try testing.expectEqual(@as(u64, 0), cold.encodeLeadSamples(0));
}

// The sweep that makes the encode lead trustworthy.
//
// A lead longer than the bar would be a silent, permanent stall: the encoder
// would be asked to generate the whole interval before it starts, so
// `produced < target` would already be false, `finalizeInterval` would never
// fire, and the session would sit there uploading nothing. So "lead < bar" is a
// correctness property, not a tidiness one.
//
// It is worth being precise about where it comes from. `encodeLeadSamples`
// ends with an explicit `@min(..., interval_len_samples)`, and at the current
// `max_slew_div = 100` that clamp is **provably unreachable**: `lead_ns` is at
// most `interval_ns / 100`, so `lead_samples` is at most `bar / 100`. The clamp
// stays because it is what makes the property true by construction rather than
// by a chain of reasoning about two constants that someone can change, and
// because it costs one `min`. This test is the belt to that pair of braces: it
// sweeps the tempos the wire can actually carry rather than trusting the
// algebra.
test "the encode lead stays strictly inside the bar across the wire's tempo range" {
    const tempos = [_][2]u16{
        // slow, normal, and the fastest a bar can plausibly be
        .{ 20, 1 },        .{ 100, 8 },   .{ 120, 4 },  .{ 137, 5 },  .{ 200, 16 },
        .{ 600, 2 },       .{ 1200, 4 },  .{ 1500, 1 }, .{ 8000, 8 }, .{ 65535, 1 },
        .{ 65535, 65535 }, .{ 1, 65535 }, .{ 1, 1 },
    };
    for (tempos) |t| {
        var c = ServerClock{};
        c.anchor(0, t[0], t[1]);
        const bar: u64 = @divTrunc(48000 * @as(u64, t[1]) * 60, t[0]);
        if (bar == 0) continue; // a bar shorter than one sample has no lead
        const lead = c.encodeLeadSamples(bar);
        std.testing.expect(lead < bar) catch |e| {
            std.debug.print("bpm={d} bpi={d} bar={d} lead={d}\n", .{ t[0], t[1], bar, lead });
            return e;
        };
        // The exact bound, for every tempo: the lead is a fraction of the
        // slew limit, which is a fraction of the bar, so the lead can never
        // exceed 1% of the bar. Stating it as an inequality rather than
        // re-deriving it is the point — this is the property, and it holds
        // whatever the tempo.
        try testing.expect(lead <= bar / 100);
        // `per_sample` is 1e9/srate — 20.8 us at 48 kHz — for *every* tempo, so
        // a bar of a few tens of samples (under ~2 ms) cannot carry a lead
        // worth naming and it rounds to zero. Correct, not a gap: such a bar is
        // over before it starts.
        if (bar >= 256) {
            // and where it can be, it is: a lead of zero would leave the final
            // flush starting exactly on the boundary, which is what #13 is about
            try testing.expect(lead > 0);
        }
    }
}

test "the drift ledger keeps the worst bar, not the last one (#13 telemetry)" {
    var c = ServerClock{};
    c.anchor(0, 120, 4);
    const start: i128 = 0;
    _ = c.nextStartNs(start, c.interval_ns + 1 * std.time.ns_per_ms);
    _ = c.nextStartNs(start, c.interval_ns + 40 * std.time.ns_per_ms); // clamped correction
    _ = c.nextStartNs(start, c.interval_ns - 2 * std.time.ns_per_ms);
    // the signed reading tracks the most recent bar ...
    try testing.expectEqual(@as(i64, -2 * std.time.ns_per_ms), c.drift_ns);
    // ... but the worst case is remembered
    try testing.expectEqual(@as(u64, 40 * std.time.ns_per_ms), c.max_abs_drift_ns);
    // every bar whose crossing was even slightly off gets a nudge, and only an
    // exactly-on-time bar is left alone (pinned by the zero-drift test above)
    try testing.expectEqual(@as(u64, 3), c.corrections);
    try testing.expectEqual(@as(i64, (1 + 20 - 2) * std.time.ns_per_ms), c.total_correction_ns);
}

fn mix(seed: u64, interval_seq: u64, channel_idx: usize, tag: []const u8) u64 {
    var h = std.hash.Wyhash.init(seed);
    var i = interval_seq;
    h.update(std.mem.asBytes(&i));
    var ci: u64 = @intCast(channel_idx);
    h.update(std.mem.asBytes(&ci));
    h.update(tag);
    return h.final();
}

/// Vorbis stream serial for (seed, interval, channel): must be pinned so the
/// encoded bytes are byte-identical across runs. `interval_seq` must be the
/// monotonic `IntervalIndex.seq`, never a grid position, or two different
/// payloads in one session can collide on a serial.
pub fn deriveSerial(seed: u64, interval_seq: u64, channel_idx: usize) u32 {
    const v = mix(seed, interval_seq, channel_idx, "kujamba-serial") & 0x7FFF_FFFF;
    return @intCast(v);
}

/// 16-byte upload guid for (seed, interval, channel). The guid is a transport
/// identifier (it never enters the 0x84 payload bytes), but it is derived
/// deterministically too so full transcripts replay consistently — and, keyed
/// off the monotonic sequence, a guid is never re-issued within a session.
pub fn deriveGuid(seed: u64, interval_seq: u64, channel_idx: usize, out: *[16]u8) void {
    const a = mix(seed, interval_seq, channel_idx, "kujamba-guid-0");
    const b = mix(seed, interval_seq, channel_idx, "kujamba-guid-1");
    std.mem.writeInt(u64, out[0..8], a, .little);
    std.mem.writeInt(u64, out[8..16], b, .little);
}
