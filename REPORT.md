# NINJAM's interval model under adverse conditions

Measured, not assumed. Every number below comes from a raw log in
`results/`, produced by one command:

```bash
./tools/run_interval_lab.sh --build-dir build
```

That builds, runs the detector self-test (and refuses to produce numbers if
it fails), runs all 11 scenarios, and regenerates `results/tables.md`. Total
wall time is about 64 minutes, almost all of it the 10-11 minute drift runs.
`./tools/run_interval_lab.sh --list` prints the scenario names;
`--only NAME[,NAME]` runs a subset; `--quick` shortens the durations.

## Headline numbers

| claim | measured |
|-------|----------|
| emission-to-playback delay at 120 BPM / 8 beats-per-interval | **8020.04 ms** (median of 6 pairs in `baseline`; 8020.02-8020.13 across all eight 4 s scenarios) |
| that delay expressed in intervals | **2.005** |
| is it a fixed time or a fixed number of intervals? | **intervals.** 2 s interval -> 4020.01 ms, 4 s -> 8020.04 ms, 8 s -> 16020.04 ms |
| max pairwise interval-alignment error, 11 min, no injected fault | **0.03 ms** |
| max pairwise alignment error, 11 min, +/-50 ppm clock drift | **0.18 ms** (predicted divergence over the run: 33 ms) |
| max pairwise alignment error, 11 min, +/-200 ppm clock drift | **0.18 ms** (predicted divergence over the run: 132 ms) |
| accumulated drift, +/-200 ppm, worst pair | **-0.00 ms/min** measured vs **-12.00 ms/min** predicted |
| where it does break: +/-8000 ppm, 11 min | alignment jumps to **7967 ms**, in **2 whole-interval slips**; residual modulo one interval **49.89 ms** |
| alignment error at 1% / 5% / 10% bidirectional message loss | **0.03 / 0.03 / 0.03 ms** - unaffected |
| markers still decoded at 1% / 5% / 10% loss | **87.5% / 84.7% / 72.2%** |
| markers still decoded at 40 ms injected jitter | **91.7%**, and those that arrive land within **0.14 ms** of each other |
| late joiner: connect -> first remote audio | **8.07 s** (120.04 s -> 128.11 s), i.e. 2.02 intervals |
| late joiner's phase vs the rest of the session | **-0.02 ms** |
| max interval-boundary phase error, any scenario, no audio involved | **0.98 ms** |

## 1. The delay is two intervals, not one

`delay` is the median over all markers of `heard_session_position - k*mark_period`,
where the emitter places marker *k* at its own session position `k*mark_period`.
It is the constant the interval model contributes.

| interval | tempo | median delay | delay / interval |
|----------|-------|--------------|------------------|
| 2000 ms | 120 BPM, 4 beats/interval | 4020.01 ms | 2.010 |
| 4000 ms | 120 BPM, 8 beats/interval | 8020.04 ms | 2.005 |
| 8000 ms | 120 BPM, 16 beats/interval | 16020.04 ms | 2.003 |

The delay scales with the interval, so it is a fixed **count** of intervals,
not a fixed time. The residual over `2 x interval` is 20.01, 20.04 and
20.04 ms across the three tempos - a constant, and consistent with codec and
loopback latency.

**Where the two intervals come from.** The server cannot forward an upload
until the interval it belongs to has closed, because only then is the audio
whole. The client then holds the received audio in a two-deep queue:
`on_new_interval()` (`ninjam/njclient.cpp:2475`) promotes `next_ds[0]` to
`ds`, shifts `next_ds[1]` to `next_ds[0]`, and clears `next_ds[1]`, while
`MESSAGE_SERVER_DOWNLOAD_INTERVAL_BEGIN` fills `next_ds[0]`. One interval is
spent at the server, one in that client pipeline.

## 2. Clock drift is absorbed, then breaks in whole-interval steps

Drift is injected by pacing each client's sample counter at
`(1 + ppm*1e-6)` times real time, which is how a bad crystal actually shows
up in `NJClient` - it advances its session clock one sample per sample played.
Three clients per run, 11 minutes, one marker every 12 s (54 markers per pair).

| scenario | ppm (l/e) | align first | align last | align max | slips | measured drift | predicted drift |
|----------|-----------|-------------|-------------|-----------|-------|----------------|-----------------|
| baseline | 0 / 0 | 0.03 | 0.03 | 0.03 | 0 | 0.00 | 0.00 |
| drift50 | 0 / +50, 0 / -50 | 0.03 | 0.11 | 0.18 | 0 | -0.00 | -3.00 |
| drift200 | 0 / +200, 0 / -200 | 0.03 | 0.09 | 0.18 | 0 | -0.00 | -12.00 |
| drift8000 | 0 / +8000, 0 / -8000 | 4000.05 | 3950.67 | 7967.41 | 2 | -740.68 | 480.00 |

`align` is the spread across client pairs of the same event, in ms.
`predicted` is `0.06 * (ppm_listener - ppm_emitter)` ms/min.

Two things to read off this:

- **At realistic drift the interval grid absorbs essentially all of it.** At
  +/-200 ppm the naive prediction is 132 ms of divergence over 11 minutes;
  the measured spread was 0.18 ms. Not 132 ms of error - 0.18 ms. The drift
  does not show up at all.
- **When it does break, it breaks discontinuously.** At +/-8000 ppm the
  alignment error does not ramp up smoothly; it jumps by whole intervals
  (2 slips, 7967 ms) and the residual once whole intervals are removed is
  49.89 ms. A client that drifts past half an interval is simply playing the
  neighbouring interval. There is no gradual degradation in between.

## 3. Message loss costs markers, not alignment

Loss is applied to the four audio-bearing message types
(`0x83`, `0x84`, `0x04`, `0x05`). Auth, config, channel-info and mask messages
are never touched, because losing those tears down the session rather than
degrading it.

| scenario | requested loss | actual drop rate | markers decoded | align max |
|----------|----------------|------------------|-----------------|-----------|
| loss1 | 1% up / 1% down | 1.35% | 87.5% | 0.03 ms |
| loss5 | 5% / 5% | 4.95% | 84.7% | 0.03 ms |
| loss10 | 10% / 10% | 9.91% | 72.2% | 0.03 ms |

Alignment is untouched at every loss level. What degrades is the audio
content: at 10% bidirectional loss, 27.8% of markers never reached a listener
intact. The session itself never desynchronised - the clock-domain probe
(still 0.00 ms median skew) confirms the grid held throughout.

## 4. Jitter displaces nothing

40 ms of jitter injected on every audio message, up and down.

| metric | value |
|--------|-------|
| messages dropped | 0 |
| markers decoded | 91.7% (66 of 72) |
| spread of arrival error across detected markers | 8020.009 to 8020.146 ms, i.e. **0.14 ms** |
| interval phase error, no audio involved | 0.00 ms median, 0.00 ms max |
| alignment error | 0.03 ms |

The audio that does arrive lands in the right place to within 0.14 ms,
because the interval clock is driven by the client's own sample counter, not
by message arrival. Network latency does not move the playout position. The
8.3% of markers that are missing is the cost of a message arriving after the
decoder has already moved past the point where it was needed.

## 5. Join in progress

A fourth client connects 120 s into a 300 s run.

| client | status OK | first remote audio | first marker decoded |
|--------|-----------|--------------------|----------------------|
| client0-2 (present from start) | 0.07 s | 20.15 s | 20.11 s |
| late3 (connects at 120 s) | 120.04 s | 128.11 s | 128.08 s |

**Time to sync: 8.07 s**, which is 2.02 intervals - the same two-interval
constant as everything else. The joiner does not have to catch up to a
running timeline; it just waits out the pipeline. Once in, its phase sits
**-0.02 ms** from the rest of the session and its delay to the existing
clients is 8020.03-8020.06 ms, indistinguishable from theirs to each other.

## 6. Claims the data contradicts

**a. "Every client plays along to the previous interval" is off by one
interval end-to-end.** The pitch describes the client-side half. Measured
emission-to-playback is 2 intervals plus 20 ms - 8020 ms at the default
tempo - because the server must also wait for the interval to close before it
can forward it. At the default 120 BPM / 8 BPI that is 8.02 seconds of
latency, not 4. The number is a fixed count of intervals, so it scales with
tempo: 4.02 s at 2 s intervals, 16.02 s at 8 s intervals.

**b. The pitch implies drift is the interesting failure mode. It isn't, until
it suddenly is.** There is no timesync message anywhere in the protocol and
the server never sends an absolute time reference, so clients have no shared
time origin to drift *from* in the first place - each client's session
timeline is its own sample counter. Consequently clock error is invisible up
to very large offsets (0.18 ms at +/-200 ppm over 11 minutes, against a
predicted 132 ms), and then reappears as a discrete whole-interval slip rather
than as accumulating skew. The honest characterisation is a bounded, quantised
error, not a drifting one.

**c. "Packet loss" is not a condition this transport can experience.** NINJAM
runs on a single TCP stream (`Net_Connection` wraps `JNL_IConnection`; there
is no UDP path), so IP-level packet loss is unobservable by construction -
TCP would convert it into latency. The loss figures above are loss of
audio-bearing `Net_Message`s, which is the coarsest granularity at which loss
can be injected at all. They are a worst case, not a network model.

**d. The interval model is more robust than advertised in the one case that
matters most - a late joiner.** 8.07 s of dead air on join, then bit-level
phase agreement. Nothing in the data suggests a joining client can disturb
the session it joins.

## 7. Measurement caveats, stated rather than smoothed over

**The clock probe's "slip rate" column is not a drift measurement.** It reads
3.7-4.3% for drift50, drift200 *and* drift8000, and exactly 0.00% for every
0-ppm scenario. A quantity that does not change across a 160x change in
injected clock error is not tracking drift. The readings it counts are all in
a 3999.0-4000.0 ms band - exactly one interval, with a sub-millisecond
residual - so they are an artifact of sampling interval phase across clients
at slightly different instants, not whole-interval slips. Consequence: the
probe bounds *phase* error tightly (max 0.98 ms wrapped, in any scenario) but
cannot be used to count slips. The audio domain in section 2 is the authority
on slips, and it is unambiguous there.

**Markers are tones, not noise.** A broadband PRBS marker was the first design
and it failed: it measured perfectly in the self-test (correlation 1.0) and
came back at ~0.15 after a real round trip, because Vorbis destroys
white-noise bursts. The tonal marker survives, correlating at 0.707 - which is
exactly `1/sqrt(2)`, the value a perfect real-cosine match scores once the
detector's template is scaled by `sqrt(2)`. Peaks of 1.0000 appear when the
path is uncorrupted. The detector is validated against known answers by
`ninjam_probe_selftest` (ctest target `ninjam_probe_selftest`): position exact
to <1 sample, chunk-boundary straddling, silence, white noise, and
cross-frequency rejection (0.0012 cross vs 1.0 self).

**Two scenarios have thin marker counts.** `interval8s` has a 20 s mark period
(the lab requires >= 2.5x the interval), so its 150 s run yields only 6 markers
per pair. Its delay ratio of 2.003 is the load-bearing number there, not the
alignment figure. `drift8000` decodes 87.7% rather than 100% because a client
that has slipped an interval puts some markers across a boundary where the
emitter's grid no longer expects them.

**How alignment is measured.** Each client broadcasts a 40 ms tone on its own
channel at session positions `k*mark_period`, client *i* at `400+300i` Hz.
Every other client runs a detector over its own output. Because no shared time
origin exists, the reported error is always a *difference* between two
listeners' answers to the same event - pairwise, never absolute.

## 8. What is still open

Each of these has a tracking issue.

- **Where exactly does the slip threshold sit?** 8000 ppm slips and 200 ppm
  does not. The interesting number - the drift at which a client first crosses
  half an interval - is between them and was not bisected. A sweep at
  500/1000/2000/4000 ppm would find it. Note the runs need to be long enough
  to accumulate past the threshold, so duration should scale inversely with
  ppm. [#20](https://github.com/drawmeanelephant/ninjam/issues/20)
- **The 20 ms residual is attributed to codec and loopback latency but not
  decomposed.** It is suspiciously stable across a 4x change in interval
  length, which suggests a fixed buffer somewhere, but nothing here localises
  it. If it turns out to be harness-side, the true interval delay is exactly
  two intervals. [#21](https://github.com/drawmeanelephant/ninjam/issues/21)
- **All clients are in one process on one machine.** Inter-client skew here is
  protocol behaviour, not network behaviour, and says nothing about a real
  link with real RTT. Real deployments add RTT the interval model has to
  absorb, which this experiment does not touch. The 40 ms jitter result hints
  that added latency displaces delivery time without moving playout time, but
  that was latency variation, not a latency offset, and 40 ms is not 200 ms.
  [#22](https://github.com/drawmeanelephant/ninjam/issues/22)
- **Loss is all-or-nothing per message.** A real lossy link truncates streams
  mid-message. Here a dropped `INTERVAL_WRITE` loses a whole chunk, which is
  the harsher case, so the 72.2% at 10% loss is a lower bound on what
  survives. [#23](https://github.com/drawmeanelephant/ninjam/issues/23)
- **Only one client per drift offset.** Every scenario uses a symmetric
  `0:+X:-X` triple, so a systematic per-client bias and a genuine clock
  difference are not separated. An asymmetric set like `0:+37:-211` would.
  Cheap to add and not yet filed.
