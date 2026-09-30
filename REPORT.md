# NINJAM's interval model under adverse conditions

Measured, not assumed. Every number below comes from a raw log in
`results/`, produced by one command:

```bash
./tools/run_interval_lab.sh --build-dir build
```

That builds, runs the detector self-test (and refuses to produce numbers if
it fails), runs all 13 scenarios, and regenerates `results/tables.md`. Total
wall time is about 67 minutes, almost all of it the 10-11 minute drift runs.
`./tools/run_interval_lab.sh --list` prints the scenario names;
`--only NAME[,NAME]` runs a subset; `--quick` shortens the durations.

## Headline numbers

| claim | measured |
|-------|----------|
| emission-to-playback delay at 120 BPM / 8 beats-per-interval | **8000.05 ms** (median of 6 pairs in `baseline`; 8000.03-8000.14 across all 4 s scenarios) |
| that delay expressed in intervals | **2.0000** |
| is it a fixed time or a fixed number of intervals? | **intervals.** 2 s interval -> 4000.02 ms, 4 s -> 8000.05 ms, 8 s -> 16000.05 ms |
| the ~20 ms residual this report used to claim | **a detector artefact**, not latency: it is half the marker burst, `(mark_len-1)/2` samples. Halving/doubling `--mark-len` halves/doubles it exactly (§1.1) |
| max pairwise interval-alignment error, 11 min, no injected fault | **0.03 ms** |
| max pairwise alignment error, 11 min, +/-50 ppm clock drift | **0.18 ms** (predicted divergence over the run: 33 ms) |
| max pairwise alignment error, 11 min, +/-200 ppm clock drift | **0.18 ms** (predicted divergence over the run: 132 ms) |
| accumulated drift, +/-200 ppm, worst pair | **-0.00 ms/min** measured vs **-12.00 ms/min** predicted |
| where it does break: +/-8000 ppm, 11 min | alignment jumps to **7967 ms**, in **2 whole-interval slips**; residual modulo one interval **49.89 ms** |
| **slip threshold** | a pair slips when accumulated relative clock error reaches **one whole interval** (see §2.1) |
| slip threshold, 660 s at a 4 s interval | measured boundary **[6000, 8000] ppm** vs predicted **6061 ppm**; 9 pairs starting aligned bracket it to **0.97-1.07 intervals** (1 outlier at 1.19 from a dropped-marker gap) |
| slip threshold in usable form | `ppm_rel = interval / duration` = **250 ppm per minute** of session at a 4 s interval |
| largest accumulated error that did **not** slip / smallest that did | **0.99 iv / 1.32 iv**, 18 pairs, **no exceptions** |
| alignment error at 1% / 5% / 10% bidirectional message loss | **0.03 / 0.03 / 0.03 ms** - unaffected |
| markers still decoded at 1% / 5% / 10% loss | **87.5% / 84.7% / 72.2%** |
| markers still decoded at 40 ms injected jitter | nominally 91.7%; under correct window accounting **100%** - nothing is lost (§4) |
| round-trip latency, 0/+50/+200 ms one-way spread across clients | **absorbed exactly**: delay stays 8000.04-8000.07 ms, the same range as baseline, alignment **0.03 ms**, grid error 0.00 ms (§5) |
| uniform +100 ms one-way for every client | **indistinguishable from baseline** (§5) |
| late joiner: connect -> first remote audio | **8.07 s** (120.04 s -> 128.11 s), i.e. 2.02 intervals |
| late joiner's phase vs the rest of the session | **-0.02 ms** |
| max interval-boundary phase error, any scenario, no audio involved | **0.98 ms** |

## 1. The delay is two intervals, not one

`delay` is the median over all markers of `heard_session_position - k*mark_period`,
where the emitter places marker *k* at its own session position `k*mark_period`.
It is the constant the interval model contributes.

| interval | tempo | median delay | delay / interval |
|----------|-------|--------------|------------------|
| 2000 ms | 120 BPM, 4 beats/interval | 4000.02 ms | **2.0000** |
| 4000 ms | 120 BPM, 8 beats/interval | 8000.05 ms | **2.0000** |
| 8000 ms | 120 BPM, 16 beats/interval | 16000.05 ms | **2.0000** |

The delay scales with the interval, so it is a fixed **count** of intervals,
not a fixed time. Once the measurement artefact described below is removed the
residual over `2 x interval` is **0.05 ms, 0.05 ms and 0.05 ms** - that is,
the delay is exactly two intervals, and what is left is under a tenth of a
millisecond.

**Where the two intervals come from.** The server cannot forward an upload
until the interval it belongs to has closed, because only then is the audio
whole. The client then holds the received audio in a two-deep queue:
`on_new_interval()` (`ninjam/njclient.cpp:2475`) promotes `next_ds[0]` to
`ds`, shifts `next_ds[1]` to `next_ds[0]`, and clears `next_ds[1]`, while
`MESSAGE_SERVER_DOWNLOAD_INTERVAL_BEGIN` fills `next_ds[0]`. One interval is
spent at the server, one in that client pipeline.

### 1.1 The 20 ms residual was the measuring instrument, not NINJAM

Earlier drafts of this report put the delay at 8020.04 ms and called the
20 ms over two intervals "consistent with codec and loopback latency". That
attribution was wrong, and it was an artefact of the harness.

The detector reports the **centre** of the correlation window
(`interval_probe.h`, `d.center_sample`), but a marker is emitted at the
**start** of its burst. Comparing a centre against a start injects exactly
half the burst length, `(mark_len-1)/2` samples, into every measurement. At the
default `mark_len=1920` that is **19.99 ms** - the entire residual.

Varying `--mark-len` separates this from real latency, because the two
predict different things: a detector centring artefact scales with the burst,
codec latency does not. Three scenarios, 200 s each:

| scenario | interval | mark_len | measured residual | half-burst | difference |
|----------|----------|----------|-------------------|------------|------------|
| mark960 | 4000 ms | 960 | **10.06 ms** | 9.99 ms | +0.07 |
| baseline | 4000 ms | 1920 | **20.05 ms** | 19.99 ms | +0.06 |
| mark3840 | 4000 ms | 3840 | **40.06 ms** | 39.99 ms | +0.07 |
| mark3840iv2s | 2000 ms | 3840 | **40.06 ms** | 39.99 ms | +0.07 |

The residual doubles when the burst doubles and halves when it halves, at both
interval lengths. A least-squares fit of residual against half-burst gives a
slope of **1.0000** times the sample period and a constant term of 0.065 ms
(3.1 samples), which does not scale with `mark_len`. Real codec latency would
sit flat at ~20 ms across all three rows and cannot produce a 4x swing.

After removing the half-burst, **every scenario in the study reads exactly
2.0000 intervals** - including the three marker lengths above, which needed
corrections of 10, 20 and 40 ms respectively to get there. That is the check
that would have caught this: an artefact that scales with the instrument
cannot also vanish when you account for the instrument.

The harness now writes `err_ms` centre-to-centre and records `err_centred 1`
so a reader does not subtract the bias twice; the analyzer removes it from logs
written before the fix. Both paths agree to 0.01 ms on `baseline`.

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
| drift3000 | 0 / +3000, 0 / -3000 | 4000.12 | 4000.16 | 4000.16 | 0 | 0.01 | 360.00 |
| drift4000 | 0 / +4000, 0 / -4000 | 4000.08 | 7967.25 | 7967.56 | 2 | -811.50 | 480.00 |
| drift6000 | 0 / +6000, 0 / -6000 | 4000.16 | 7966.53 | 7967.55 | 2 | -1106.57 | 720.00 |
| drift8000 | 0 / +8000, 0 / -8000 | 4000.05 | 3950.67 | 7967.41 | 2 | -740.68 | 480.00 |
| drift12000 | 0 / +12000, 0 / -12000 | 4000.00 | 7973.54 | 7973.75 | 2 | -1120.24 | 720.00 |

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

### 2.1 The slip threshold is one whole interval of accumulated clock error

The five drift rungs above, plus the sub-interval residuals, locate the
threshold. What matters is not the drift *rate* but the clock error a pair has
**accumulated** by the time the session ends: `ppm_rel * duration`. A pair
slips when that product reaches one interval.

For the 660 s runs at a 4 s interval, each rung lands at a known fraction of an
interval, and each run also contains a pair at twice the nominal offset
(`0:+X:-X` makes the 1<-2 pair 2X), so one run yields two rungs:

| scenario | pair | ppm rel | accumulated at run end | slipped? |
|----------|------|---------|-------------------------|----------|
| drift200 | 1<-2 | +400 | 0.07 iv | no |
| drift3000 | 1<-2 | +6000 | 0.99 iv | no |
| drift4000 | 1<-0 | +4000 | 0.66 iv | no |
| drift4000 | 1<-2 | +8000 | 1.32 iv | **yes** |
| drift6000 | 1<-0 | +6000 | 0.99 iv | no |
| drift6000 | 1<-2 | +12000 | 1.98 iv | **yes** |
| drift8000 | 1<-0 | +8000 | 1.32 iv | **yes** |
| drift8000 | 1<-2 | +16000 | 2.64 iv | **yes** |
| drift12000 | 1<-0 | +12000 | 1.98 iv | **yes** |
| drift12000 | 1<-2 | +24000 | 3.96 iv | **yes** |

Counting every one of the 18 client pairs whose relative offset is positive and
which started the session aligned to the 2-interval baseline:

- Largest accumulated error with **no** slip: **0.99 intervals** (three pairs
  at +6000 ppm).
- Smallest accumulated error **with** a slip: **1.32 intervals** (three pairs
  at +8000 ppm).
- **No exceptions.** Every pair above 1 interval slipped; every pair below did
  not.

Measuring *when* each slip happens brackets the threshold from both sides. A
slip is only *observed* at a marker, so the honest measurement is a bracket: the
accumulated error at the **last marker still aligned** is a lower bound, and the
accumulated error at the **first marker past the threshold** is an upper bound.
Every client pair that started the session aligned to the 2-interval baseline:

| scenario | pair | ppm rel | last aligned | lower bound | first slipped | upper bound |
|----------|------|---------|--------------|-------------|----------------|-------------|
| drift4000 | 1<-2 | +8000 | t=498.1 | **1.00 iv** | t=514.1 | 1.03 iv |
| drift6000 | 1<-2 | +12000 | t=330.1 | **0.99 iv** | t=346.0 | 1.04 iv |
| drift8000 | 1<-0 | +8000 | t=496.2 | **0.99 iv** | t=512.1 | 1.02 iv |
| drift8000 | 0<-2 | +8000 | t=488.1 | **0.98 iv** | t=528.2 | 1.06 iv |
| drift8000 | 0<-1 | -8000 | t=500.1 | **1.00 iv** | t=520.2 | 1.04 iv |
| drift12000 | 1<-0 | +12000 | t=328.1 | **0.98 iv** | t=344.0 | 1.03 iv |
| drift12000 | 0<-2 | +12000 | t=332.1 | **1.00 iv** | t=348.1 | 1.04 iv |
| drift12000 | 1<-2 | +24000 | t=162.1 | **0.97 iv** | t=178.0 | 1.07 iv |
| drift8000 | 1<-2 | +16000 | t=246.1 | **0.98 iv** | t=297.8 | 1.19 iv |

The lower bounds cluster tightly at **0.97-1.00 intervals**; the upper bounds
are **1.02-1.07** for eight of the nine, with one outlier at 1.19 explained
below. The threshold is 1.000 intervals, resolved to within one marker period.

Three pairs that slipped are **not** in that table, and the reason matters:

- **`drift8000 1<-2` (+16000 ppm) reads 1.19 iv, not ~1.03.** Its markers
  k=21..24 were dropped, so the bracket spans a **51.6 s** gap instead of the
  nominal 12 s. The slip still happened at 1.00; the *observation* of it was
  just late. Marker gaps in these runs are not uniformly 12 s: the median is
  12.0 s but the maximum is 87.2 s, because a slipping pair also loses markers.
  Any single-marker reading is therefore only as good as the gap before it.
- **Two pairs start a whole interval off before any drift** and so need two
  intervals of accumulated error to show a transition:

| scenario | pair | ppm rel | last aligned | lower bound | first slipped | upper bound |
|----------|------|---------|--------------|-------------|----------------|-------------|
| drift8000 | 2<-1 | -16000 | t=500.1 | 2.00 iv | t=520.4 | 2.08 iv |
| drift12000 | 2<-1 | -24000 | t=332.0 | 1.99 iv | t=340.2 | 2.04 iv |

  These are the startup-offset pairs described in §9. Their first transition
  is a *second* boundary crossing relative to where they started, and it lands
  at exactly 2 intervals as the same one-interval rule predicts.
- **Some pairs slip back.** Three pairs cross the boundary and later return to
  the offset they started at (`drift12000 1<-2` goes 0 -> -2 -> -1 -> 0). The
  offset is not monotonic in accumulated drift, so "slips" is not a one-way
  ratchet. The first crossing is still the reliable measurement.

So: **9 pairs starting aligned bracket the threshold to 0.97-1.07 intervals, 2
pairs starting a whole interval off cross at 1.99-2.08, and the 1.19 outlier
is a dropped-marker artefact, not a disagreement.** Every number above is
regenerated by `tools/analyze_interval_lab.py` and cross-checked against this
file by `tools/verify_report_brackets.py`, which fails if the prose and the
tables disagree.

**The practical form of the result.** For a session of duration `T` at interval
`L`, a client pair slips when

    ppm_rel_threshold  =  L / T

For a 4 s interval that is 250 ppm per minute of session: a 10-minute jam needs
2500 ppm relative to break, an hour needs 67 ppm. The measured boundary for the
660 s runs is bracketed to **[6000, 8000] ppm** against a predicted 6061 ppm.
A consumer audio interface at 20 ppm would take about 2.8 hours to slip one
interval against a perfect reference, so for realistic hardware this is not a
failure mode - which is presumably why the interval model has survived as long
as it has.

**This contradicts the design assumed in issue #20**, which proposed that run
durations "scale inversely with ppm". That would hold accumulated drift roughly
constant and re-measure the same point at every rung instead of finding the
boundary. Holding duration *fixed* and stepping ppm is what walks the
accumulated error across the threshold, and it is 4x cheaper here. The clock
probe still cannot count slips, as #20 warns; the count above comes from the
marker trace, via a new `slip_t` field in the analyzer.

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
| markers decoded | 91.7% (66 of 72) - but see below: nothing was actually lost |
| spread of arrival error across detected markers | 8000.009 to 8000.146 ms, i.e. **0.14 ms** |
| interval phase error, no audio involved | 0.00 ms median, 0.00 ms max |
| alignment error | 0.03 ms |

The audio that does arrive lands in the right place to within 0.14 ms,
because the interval clock is driven by the client's own sample counter, not
by message arrival. Network latency does not move the playout position.

**Correction made while measuring #22: no marker was actually lost here.**
This section used to read "the 8.3% of markers that are missing is the cost of
a message arriving after the decoder has already moved past the point where it
was needed". That attribution was wrong. Every scenario with 12 s markers
misses exactly marker k=0 of each client - jitter, rtt-spread and rtt100 all
drop k=0 and nothing else, which no per-message fault explains (loss5 drops
markers at random k). k=0's playout lands at/after the run's end window, so it
was never measurable in these runs; the numerator should not have counted it.
Under correct accounting jitter costs **zero** markers, which matches the
"displaces nothing" headline far better than the old 8.3% did.

## 5. Real round-trip latency is absorbed exactly like jitter

Issue #22 asks whether the interval model absorbs a real deployment's RTT, or
whether clients at different distances from the server drift apart. The
scenario axis is a per-client one-way added latency (`--client-delay`, applied
in each direction, client->server and server->client - what a real RTT looks
like to the protocol). `rtt-spread` puts three clients at
0 / +50 / +200 ms one-way; `rtt100` gives every client +100 ms, to separate
"latency" from "latency spread between clients". 200 s each, otherwise
identical to baseline.

| scenario | added one-way latency per client | median delay (pair range) | delay / interval | align max | align mod iv | clock phase max | audio msgs dropped |
|----------|----------------------------------|---------------------------|------------------|-----------|--------------|-----------------|--------------------|
| baseline | 0 / 0 / 0 ms | 8000.04-8000.07 ms | 2.0000 | 0.03 ms | 0.00 ms | 0.00 ms | 0 |
| rtt-spread | 0 / +50 / +200 ms | 8000.04-8000.07 ms | 2.0000 | 0.03 ms | 0.00 ms | 0.00 ms | 0 |
| rtt100 | +100 / +100 / +100 ms | 8000.04-8000.07 ms | 2.0000 | 0.03 ms | 0.00 ms | 0.00 ms | 0 |

The delay column does not move at all: both rtt runs land in the same
8000.04-8000.07 ms range as baseline, to the last digit. Had the added latency
reached playout, rtt-spread's six pairs would have spread across a 250 ms range
and every pair would have sat ~200 ms above baseline. Alignment, the wrapped
grid error and the clock-domain probe are equally unmoved, and both runs
decoded every marker that was measurable (the nominal 93.8% is the window
arithmetic described in §8, not loss: zero audio messages were dropped).

That the injection really happened is visible per client rather than taken on
trust: in `rtt-spread` the per-client `audio_msgs_delayed` column reads 0 of 98
for client0 (correctly no delay) and 98 of 98 for clients 1 and 2, while
`rtt100` reads 98 of 98 for all three. The spread is genuinely distinct per
client, and none of it reaches playout.

The issue's prediction was that added latency displaces audio in delivery
time without moving it in playout time, on the analogy of the 40 ms jitter
result. Measured, it does not even displace delivery: the emission-to-playback
delay stays exactly two intervals with no added constant. The reason is that
the pipeline already runs on interval slack - the server cannot forward an
upload until its interval closes (§1), and an upload that arrives 200 ms into
its own interval and one that arrives 200 ms plus RTT late both make the same
interval close. Playout is pinned to the interval boundary either way, so the
extra delivery time is absorbed by slack the model always had. The 40 ms
jitter reading extends to 200 ms unchanged.

Where would RTT start to matter? Only where it stops being small against the
interval: a one-way latency plus jitter approaching the interval length (4 s
here) would push uploads past the interval close, and a latency *spread*
approaching half an interval (2 s) would put clients a whole interval apart.
Real RTTs sit two to three orders of magnitude below both, so the interval
model's latency budget is effectively the interval itself, and RTT does not
consume it.

**Instrumentation note.** A symmetric per-client delay cannot live in the
send-side injector alone: one process receives on behalf of every other
participant, all on shared threads, so "hold what I receive for X ms" must be
a property of the thread running the receiving connection.
`Net_Connection` now mirrors its send-side delay queue on the receive side
(`m_rxdelayq`), with the same closed-form properties: only the four audio
message types are held, due times are clamped non-decreasing so the stream
can never reorder, and the wire stays gated while anything is parked. Both
halves of a client's one-way latency are applied from the client end (its own
pump thread), because the server pumps every connection on one thread and a
hold set there would be last-wins across all of them.

## 6. Join in progress

A fourth client connects 120 s into a 300 s run.

| client | status OK | first remote audio | first marker decoded |
|--------|-----------|--------------------|----------------------|
| client0-2 (present from start) | 0.07 s | 20.15 s | 20.11 s |
| late3 (connects at 120 s) | 120.04 s | 128.11 s | 128.08 s |

**Time to sync: 8.07 s**, which is 2.02 intervals - the same two-interval
constant as everything else. The joiner does not have to catch up to a
running timeline; it just waits out the pipeline. Once in, its phase sits
**-0.02 ms** from the rest of the session and its delay to the existing
clients is 8000.03-8000.06 ms, indistinguishable from theirs to each other.

## 7. Claims the data contradicts

**a. "Every client plays along to the previous interval" is off by one
interval end-to-end.** The pitch describes the client-side half. Measured
emission-to-playback is 2 intervals - 8000 ms at the default tempo - because
the server must also wait for the interval to close before it can forward it.
At the default 120 BPM / 8 BPI that is 8.00 seconds of latency, not 4. The
number is a fixed count of intervals, so it scales with tempo: 4.00 s at 2 s
intervals, 16.00 s at 8 s intervals.

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

## 8. Measurement caveats, stated rather than smoothed over

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

**Marker counts in short runs are a window artefact.** In any run of length
`T` with markers every `mark_period`, the last marker's playout lands about
two intervals after its emission - at or past `T` - so the final marker of the
run is never measurable, and with the window aligned the way these runs are,
the *first* marker (k=0) is not either. This cost the study a real
misattribution: the jitter section used to blame 8.3% of markers on "a message
arriving after the decoder had moved past the point where it was needed",
when the same 6-row deficit appears with zero messages dropped in every
150-200 s scenario. Read detection percentages against the measurable window,
not the nominal emission count (§4).

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
per pair. Its delay ratio of 2.0000 is the load-bearing number there, not the
alignment figure. `drift8000` decodes 87.7% rather than 100% because a client
that has slipped an interval puts some markers across a boundary where the
emitter's grid no longer expects them.

**How alignment is measured.** Each client broadcasts a 40 ms tone on its own
channel at session positions `k*mark_period`, client *i* at `400+300i` Hz.
Every other client runs a detector over its own output. Because no shared time
origin exists, the reported error is always a *difference* between two
listeners' answers to the same event - pairwise, never absolute.

## 9. What is still open

Each of these has a tracking issue.

- **Where exactly does the slip threshold sit?** Answered in §2.1: a pair slips
  when accumulated relative clock error reaches one whole interval, i.e.
  `ppm_rel = L / T`. Measured boundary for 660 s at a 4 s interval is
  [6000, 8000] ppm against a predicted 6061 ppm. Nine pairs that started
  aligned bracket the threshold to 0.97-1.07 intervals. The issue's suggested
  design (durations scaling inversely with ppm) was the wrong way round and
  would have measured the same point repeatedly.
  [#20](https://github.com/drawmeanelephant/ninjam/issues/20)
- ~~**The 20 ms residual is attributed to codec and loopback latency but not
  decomposed.**~~ **Resolved, and the attribution was wrong.** It is the
  detector comparing a correlation *centre* against a marker emitted at its
  *start*, injecting half the marker burst — `(mark_len-1)/2` samples. Scaling
  `--mark-len` scales the residual exactly, which codec latency cannot do. The
  true interval delay is exactly two intervals with a 0.05 ms residual, and
  every scenario now reads 2.0000. See §1.1. Fixed in the harness.
  [#21](https://github.com/drawmeanelephant/ninjam/issues/21)
- ~~**All clients are in one process on one machine.** Inter-client skew here
  is protocol behaviour, not network behaviour.~~ **Resolved for RTT, which
  was the open question.** A symmetric per-client added latency of 0/+50/+200
  ms one-way (issue #22's suggested spread) moves nothing: the delay column
  stays in baseline's exact 8000.04-8000.07 ms range, alignment stays at
  0.03 ms, and the uniform +100 ms control is indistinguishable from
  baseline (§5). The remaining
  one-process caveat now covers clock skew sources and multi-hop routing, not
  latency. The 40 ms jitter "hint" turned out to understate the result: added
  latency does not even displace delivery time, because the pipeline runs on
  interval slack. Measuring it needed a receive-side injector, since one
  process receives for every participant on shared threads (§5
  instrumentation note).
  [#22](https://github.com/drawmeanelephant/ninjam/issues/22)
- **Loss is all-or-nothing per message.** A real lossy link truncates streams
  mid-message. Here a dropped `INTERVAL_WRITE` loses a whole chunk, which is
  the harsher case, so the 72.2% at 10% loss is a lower bound on what
  survives. [#23](https://github.com/drawmeanelephant/ninjam/issues/23)
- **Some pairs start a whole interval off before any drift accumulates.** This
  turned up while validating §2.1 and is not drift at all. In every run with
  offsets of 3000 ppm or more, several client pairs measure 4020 ms instead of
  8020 ms on their *very first* marker - a full interval of misalignment
  present at t=0, before a millisecond of clock error has built up. It appears
  at 3000 ppm and above and not at 200 ppm or below, and which pairs get it
  is not a simple function of the sign of the offset. The most likely cause is
  the startup transient: a client whose sample counter runs fast crosses an
  extra interval boundary while the session is still coming up, and the
  interval model has no way to express a fractional position, so the error
  lands on the interval grid. This is a *join-time* quantisation and it is not
  in the §2.1 threshold numbers, which use only the pairs that start aligned.  It is worth its own experiment: it means
  a badly-clocked client can be a whole interval out before it has played a
  note, which is a sharper failure than slow drift.
  [#25](https://github.com/drawmeanelephant/ninjam/issues/25)
- **A detector artefact that looks like signal.** `peak` is clamped to 1.0
  (`interval_probe.h`), and the value 1.0000 appears on exactly the post-slip
  rows across every slipping pair. It is the correlation saturating, not the
  marker arriving more cleanly; reading it as improved detection would be
  wrong. Noted in the analyzer's integrity section so it is not rediscovered as
  a finding.
- **Only one client per drift offset.** Every scenario uses a symmetric
  `0:+X:-X` triple, so a systematic per-client bias and a genuine clock
  difference are not separated. An asymmetric set like `0:+37:-211` would.
  Cheap to add and not yet filed.
