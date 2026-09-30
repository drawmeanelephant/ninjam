# NINJAM's interval model under adverse conditions

Measured, not assumed. Every number below comes from a raw log in
`results/`, produced by one command:

```bash
./tools/run_interval_lab.sh --build-dir build
```

That builds, runs the detector self-test (and refuses to produce numbers if
it fails), runs all 19 scenarios, and regenerates `results/tables.md`. Total
wall time is about 145 minutes, dominated by the eight 11-minute drift runs.
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
| slip threshold in usable form | `ppm_rel = 1e6 * interval_s / duration_s` = **66,700 ppm per minute** of session at a 4 s interval, so 6,670 ppm for a 10-minute jam and 1,110 ppm for an hour |
| largest accumulated error that did **not** slip / smallest that did | **0.99 iv / 1.32 iv**, 18 pairs, **no exceptions** |
| does the threshold scale with the interval, or is it a fixed drift rate? | **it scales with the interval.** Measured boundary **[3000, 3953] / [6000, 7809] / [12000, 15748] ppm** at 2 / 4 / 8 s, against 3030 / 6061 / 12121 predicted: it doubles with the tempo (§2.2) |
| alignment error at 1% / 5% / 10% bidirectional message loss | **0.03 / 0.03 / 0.03 ms** - unaffected |
| markers still decoded at 1% / 5% / 10% loss | **87.5% / 84.7% / 72.2%** |
| markers still decoded at 40 ms injected jitter | nominally 91.7%; under correct window accounting **100%** - nothing is lost (§4) |
| round-trip latency, 0/+50/+200 ms one-way spread across clients | **absorbed exactly**: delay stays 8000.04-8000.07 ms, the same range as baseline, alignment **0.03 ms**, grid error 0.00 ms (§5) |
| uniform +100 ms one-way for every client | **indistinguishable from baseline** (§5) |
| late joiner: connect -> first remote audio | **8.07 s** (120.04 s -> 128.11 s), i.e. 2.02 intervals |
| late joiner's phase vs the rest of the session | **-0.02 ms** |
| max interval-boundary phase error, any scenario, no audio involved | **0.98 ms** |
| a short (not lost) audio write, 5% of writes cut by 2000 B | **silently accepted**: no error path, no log line from either end, session stays up, delay still 2.0000 intervals, alignment 0.02 ms |
| what one short write costs | the **rest of the interval it landed in and nothing else**: median start 266 ms into a 2 s interval, median 1646 ms lost, **27 of 27 gaps end exactly on an interval boundary**, longest gap 0.87 intervals |
| does it bleed into the next interval? | **no.** Each interval carries its own Ogg headers, so the decoder re-initialises at every boundary and the next interval plays normally (§6) |
| is a *lost* message worse than a short one? | **yes, at the same 5% rate: 47 damaged intervals vs 27**, markers heard 52-57 of 60 vs 57-59 of 60, and the worst lost-message gap reached **1.88 intervals** - longer than a whole interval, where no short write ever did (§6) |
| one truncated *upload* vs one truncated *download* | a download is private to the client that received it (19 of 23 intervals hit one client); an upload is forwarded by the server and hits **every other participant at the same instant** (11 of 12 intervals hit two clients, 9 of those on the same emitter) (§6) |
| a byte dropped mid-message (8 B), downlink | **kills the session outright**: affected clients end at `NJC_STATUS_DISCONNECTED`, 0 markers, peers untouched (§6) |
| a byte dropped mid-message (8 B), uplink | kills that one user; the server logs `code=-1` and serves the rest. At 3% all three users were gone within 70 s (§6) |
| can the client tell corruption from a dead network? | **yes, by the error string** - the status code is `1002` either way, but `GetErrorStr()` now says the stream was corrupted rather than that the connection was lost (issue #29, §6) |

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

  These are the startup-offset pairs described in §10. Their first transition
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
`L`, a client pair slips when the relative clock error accumulated over the
session reaches one whole interval:

    ppm_rel_threshold  =  1e6 * L_s / T_s        ( = 1000 * L_ms / T_s )

The one number to check this against is the measured one: at a 4 s interval and
a 660 s run it gives 6061 ppm, and the measured boundary is bracketed to
**[6000, 8000] ppm**. At a 4 s interval that is 66,700 ppm per minute of
session, so a 10-minute jam needs 6,670 ppm relative to break and an hour
needs 1,110 ppm. A consumer audio interface at 20 ppm needs about 55 hours -
2.3 days - to slip one interval against a perfect reference, so for realistic
hardware this is not a failure mode, which is presumably why the interval
model has survived as long as it has.

(Those worked figures were wrong by more than an order of magnitude in the
first draft of this section, which quoted 2500 ppm for ten minutes and 2.8
hours for a 20 ppm interface. Both are self-refuting against the formula
printed above them: 2500 ppm over ten minutes accumulates 1.5 s, which is 0.37
of a 4 s interval and cannot break anything, and 20 ppm for 2.8 h accumulates
0.2 s. They are replaced by the arithmetic above, anchored on the measured
660 s / 4 s boundary so it can be checked in one step.)

**This contradicts the design assumed in issue #20**, which proposed that run
durations "scale inversely with ppm". That would hold accumulated drift roughly
constant and re-measure the same point at every rung instead of finding the
boundary. Holding duration *fixed* and stepping ppm is what walks the
accumulated error across the threshold, and it is 4x cheaper here. The clock
probe still cannot count slips, as #20 warns; the count above comes from the
marker trace, via a new `slip_t` field in the analyzer.

### 2.2 The threshold is in intervals, not in ppm

§2.1 leaves one of issue #20's two questions open: is the threshold one whole
interval of accumulated error, so that the *ppm* at which it happens scales
with the interval, or is it an absolute drift rate that does not move when the
tempo does? **It scales with the interval.**

The 4 s ladder above cannot answer this, which is why it was missed: at a
fixed 660 s both readings predict the same number, 6061 ppm. The two only
diverge if the interval is changed. So the ladder was repeated at 2 s and 8 s
(`drift2000iv2s` .. `drift4000iv2s`, `drift6000iv8s` .. `drift12000iv8s`, all
660 s, same `0:+X:-X` shape), choosing rungs that put the two readings on
opposite sides of the boundary:

| interval | runs | pairs that slipped | measured threshold | predicted `L / T` | largest error with no slip | smallest error with a slip |
|----------|------|--------------------|--------------------|-------------------|---------------------------|---------------------------|
| 2 s | 3 | 7 | **[3000, 3953] ppm** | 3030 ppm | 0.99 iv (3000 ppm) | 0.97 iv (8000 ppm) |
| 4 s | 7 | 9 | **[6000, 7809] ppm** | 6061 ppm | 0.99 iv (6000 ppm) | 0.97 iv (24000 ppm) |
| 8 s | 3 | 2 | **[12000, 15748] ppm** | 12121 ppm | 0.99 iv (12000 ppm) | 0.98 iv (16000 ppm) |

Each measured boundary contains the predicted one, and the boundaries double
along with the interval. Per-pair brackets at the two new tempos, on the same
terms as the §2.1 table:

| scenario | pair | ppm rel | last aligned | lower bound | first slipped | upper bound | interval ms |
|----------|------|---------|--------------|-------------|----------------|-------------|-------------|
| drift2000iv2s | 1<-2 | +4000 | t=495.1 | **0.99 iv** | t=509.0 | 1.02 iv | 2000 |
| drift3000iv2s | 1<-2 | +6000 | t=327.1 | **0.98 iv** | t=341.0 | 1.02 iv | 2000 |
| drift4000iv2s | 0<-1 | -4000 | t=496.1 | **0.99 iv** | t=506.1 | 1.01 iv | 2000 |
| drift4000iv2s | 0<-2 | +4000 | t=496.1 | **0.99 iv** | t=510.1 | 1.02 iv | 2000 |
| drift4000iv2s | 1<-0 | +4000 | t=494.1 | **0.99 iv** | t=508.0 | 1.02 iv | 2000 |
| drift4000iv2s | 1<-2 | +8000 | t=243.1 | **0.97 iv** | t=257.0 | 1.03 iv | 2000 |
| drift4000iv2s | 2<-0 | -4000 | t=498.1 | **1.00 iv** | t=508.1 | 1.02 iv | 2000 |
| drift8000iv8s | 1<-2 | +16000 | t=492.1 | **0.98 iv** | t=519.9 | 1.04 iv | 8000 |
| drift12000iv8s | 1<-2 | +24000 | t=332.1 | **1.00 iv** | t=359.7 | 1.08 iv | 8000 |

These nine pairs, with the nine at 4 s in §2.1, bracket the threshold to
**0.97-1.08 intervals** at the two new tempos and 0.97-1.19 over all eighteen
(the 1.19 being the §2.1 dropped-marker outlier). So the quantity that does
not depend on the tempo is the interval count, and the ppm figure is just that
count divided by the run length.

**The single cleanest demonstration needs one run at each of two tempos.**
`drift12000` and `drift12000iv8s` inject exactly the same +/-12000 ppm. Over
660 s that is 7.92 s of accumulated relative error in both. At a 4 s interval
that is **1.98 intervals**, and all three pairs that started aligned slip -
each reaching a full two intervals from where it started, one of them back at
zero again by the end. At an 8 s interval the same error is **0.99 intervals**
and not one of them slips. Same drift, same duration, same clients, opposite
outcome, decided entirely by the interval length. A fixed drift rate would
have given the same answer at both tempos.

Two honest caveats on the new runs:

- **The 1.08 upper bound is a dropped marker, not a disagreement.** In
  `drift12000iv8s 1<-2` the marker k=17 never arrives, so the bracket spans
  27.7 s instead of the 20 s grid (`drift8000iv8s 1<-2` drops k=25 the same
  way, for its 1.04). This is the §2.1 dropped-marker artefact reproduced at
  another tempo, and it is why a single-marker reading is never used as the
  threshold.
- **A `2<-1` pair starts a whole interval off in both 2 s runs** (t=2000.06 ms
  where the baseline is 4000), so it is the §2.1 second-crossing case and is
  excluded from the table above:

| scenario | pair | ppm rel | last aligned | lower bound | first slipped | upper bound | interval ms |
|----------|------|---------|--------------|-------------|----------------|-------------|-------------|
| drift4000iv2s | 2<-1 | -8000 | t=496.0 | 1.98 iv | t=506.1 | 2.02 iv | 2000 |

  which is the same one-interval rule read from one interval further along.

One incidental result worth recording against §10: the startup offset of
[#25](https://github.com/drawmeanelephant/ninjam/issues/25) is **not** specific
to a 4 s tempo or to 3000 ppm - it is in **all six** of the new runs, at both
new tempos and every offset tried. How many pairs get it does vary with the
tempo (3 of 6 at 8 s, 1-2 of 6 at 2 s), but `2<-1` is offset in every single
run, and at 4 s and 8 s the offset pairs are the same three (`0<-1`, `2<-0`,
`2<-1`) every time. It looks like a property of the session start-up and of
which client that is, not of the interval or of the injected error.

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
arithmetic described in §9, not loss: zero audio messages were dropped).

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

## 6. A short message is not a lost message, and it is not detected

Issue #23 asks about the case §3 cannot reach: not a whole `INTERVAL_WRITE`
vanishing, but the same write arriving with the tail of its payload missing.
The issue frames this as what a real lossy link does, and that framing turns
out to conflate two faults that behave nothing alike, so both are measured
here.

A message is a type byte plus a 32-bit length and nothing else - no resync
marker, no checksum, no sequence number. That gives two distinct faults:

- **A short message.** Framing intact, payload truncated. The sender's
  message boundary still lines up with the receiver's, so the receiver cannot
  tell it from a complete write. This is what something that re-chunks or
  trims *at the message layer* produces - a proxy, a middlebox with a buffer
  limit, a sender-side cap.
- **A truncated byte stream.** Bytes gone from the middle of a message. Since
  the transport is one ordered TCP stream, this is what an actual network
  fault produces - and because the framing has no resync marker, every
  message after the hole is read at the wrong offset.

The issue's wording ("a real lossy link truncates streams mid-message") names
the second while the harness it suggests can only produce the first. Measuring
both is the point of this section, and they do not resemble each other: the
first costs a fraction of one interval, the second ends the session.

`mpb_server_download_interval_write::parse` (`ninjam/mpb.cpp:434`) shows why the
short case is invisible - it derives `audio_data_len` from the message size:

```c
if (msg->get_size() < 17) return 1;
...
audio_data = p;
audio_data_len = msg->get_size()-17;
```

There is nothing to compare that against, so a message that is 2000 bytes
short parses exactly like a complete one. The client appends it to the
interval's decode buffer and the session carries on.

Six scenarios, 200 s each, at a 2 s interval with a 6.5 s mark period. 6500
mod 2000 = 500, so markers land at four distinct offsets inside an interval and
damage can be attributed to the interval it happened in. `--steady` adds a
quiet 250 Hz tone to every channel, which turns each remote channel's decoded
level into a continuous measure of whether its audio is flowing; the gaps below
are measured in that level at the clock probe's 10 Hz. `truncbase` is the
control and differs from the others only in tempo, mark period and that tone.

| scenario | what is damaged | clients alive at end | markers heard (of 60 possible) |
|----------|-----------------|----------------------|--------------------------------|
| truncbase | nothing injected | 3 of 3 | 60, 60, 60 |
| truncdown | 5% of the writes a client **receives**, 2000 B cut from each | 3 of 3 | 57, 58, 59 |
| truncup | 5% of the writes the **server receives**, 2000 B cut from each | 3 of 3 | 59, 59, 60 |
| truncloss | 5% of received writes **dropped whole** (the §3 case) | 3 of 3 | 52, 57, 57 |
| desync | 3% of received messages lose **8 bytes mid-body** | **1 of 3** | 0, 0, 1 |
| desyncup | 3% of the server's received messages lose 8 bytes mid-body | **0 of 3** | 0, 0, 0 |

**The decoder does none of the three things the issue was worried about.** It
does not error, it does not emit garbage, and it does not hang. The damaged
span decodes to silence: the median level inside a gap is 0.0043 against a live
level of 0.0127 on the same channel, and in the control run no sample of any
channel ever falls below the detection threshold at all - the two states are
genuinely distinct, not a threshold artefact. Every client ended the run at
`NJC_STATUS_OK`, alignment stayed at 0.02 ms with zero whole-interval slips,
and the emission-to-playback delay stayed at 2.0000 intervals (4000.05-4000.11
ms across the four non-desync runs). The model is undisturbed by short writes.

**What a short write costs is the rest of its interval, and not one sample
more.**

| scenario | gaps measured | audio stops this far into the interval | median gap | longest gap | longest / interval | gaps ending exactly on an interval edge |
|----------|---------------|----------------------------------------|------------|-------------|--------------------|------------------------------------------|
| truncbase | 0 | - | - | - | - | - |
| truncdown | 27 | 266 ms | 1646 ms | 1741 ms | **0.87** | **27 / 27** |
| truncup | 26 | 251 ms | 1732 ms | 1745 ms | **0.87** | **26 / 26** |
| truncloss | 47 | 275 ms | 1636 ms | 3767 ms | **1.88** | 47 / 47 |

So the answer to "does corruption bleed into the next interval" is no. A hole in
the middle of one interval's stream stalls that interval, and the boundary
hands the decoder a fresh stream that starts with headers again.
`VorbisDecoder::DecodeWrote` (`WDL/vorbisencdec.h`) does exactly that when the
page serial number changes, clearing the decoder and re-initialising it; that
recovery landing precisely on interval edges, 53 times out of 53, is the
evidence that each interval's audio is its own Ogg stream rather than a
continuation. **The interval grid is also the error boundary**: corruption
cannot propagate past an interval edge, because the next interval does not
depend on the damaged bytes. The 10 Hz sampling puts a +/-100 ms bound on each
edge, and every one of the 53 short-write gaps falls inside it.

**A lost message is worse than a short one, which is the opposite of how the
issue frames the question.** At the same nominal 5%, dropping
messages whole damaged 47 intervals against 27 for cutting them short, cost
more markers (52-57 of 60 against 57-59), and produced gaps that reached
**1.88 intervals** - longer than a whole interval, so 4 of the 47 spanned a
boundary - where no short write ever exceeded 0.87. The likely reason is what a lost message takes with it: a
truncated write still delivers the start of its block, so the decoder gets
whatever came before the cut, whereas a message that never arrives removes a
whole ~8 kB block including the pages the next write continues from.Those 4 loss gaps are the one number here I cannot fully account for from
the code; it would need the decoder's serial and state trace to settle, and it
is left as an open item rather than explained away.

**Direction decides who pays.** A truncated *download* is private to the client
that received it. A truncated *upload* is forwarded by the server to everyone
else, so one damaged write costs every other participant the same interval at
the same instant:

| scenario | intervals with a gap | only 1 client affected | 2 clients affected | 3 clients affected | 2+ clients lost the same emitter |
|----------|----------------------|------------------------|--------------------|--------------------|-----------------------------------|
| truncdown | 23 | 19 | 4 | 0 | 1 |
| truncup | 12 | **0** | 11 | 1 | **9** |
| truncloss | 38 | 31 | 7 | 0 | 3 |

The `truncup` row is the signature: no interval damages a single client, and in
9 of the 11 two-client intervals both lost the *same emitter index*, which two
independent rolls would not reproduce. The 4 two-client intervals in `truncdown`
are two rolls landing in the same interval by chance, and only 1 of those
shares an emitter index. One client's bad write, two victims - and the
originating client is not one of them.

**A byte dropped mid-message is a different failure entirely, and the framing
cannot survive it.** This is the case the issue's framing ("truncation") points
at and the one that actually matters in deployment. Losing 8 bytes from the
middle of a message body leaves every subsequent message misparsed, because
the framing is a bare length with no resync marker to search for: the header of
whatever comes next is read out of audio data. In the downlink run, both
affected clients ended at `NJC_STATUS_DISCONNECTED` with zero markers decoded,
and each one's session clock stopped advancing within one 100 ms sample of the
drop - at the drop's own session position, so the failure is detected at once
rather than after a timeout. The third client, untouched, ran the full 200 s
and finished healthy. On the uplink the server drops that one user and carries
on serving the rest (`disconnected (username:'client2@...', code=-1)` in the
server log, three separate entries 8 s and 56 s apart); at 3% all three users
were gone within 70 s and the session ended with the server still up.

The client reports a plain disconnect. `NJClient::Run` sets `m_status=1002` on
any transport error and sets no error string, so a stream that was silently
mangled is indistinguishable to the user from a network that went away. There
is no recovery path short of reconnecting, and no diagnostic that says why.

**That diagnostic now exists (issue #29); the recovery does not.** The framing
result above is unchanged - a desynchronised stream is still unrecoverable,
because there is no resync marker to search for - but the client no longer
reports a bare status. `Net_Connection` was already distinguishing these
faults: only the *sign* of `GetStatus()` separated "the message stream went
bad" from "the socket went away", and both reached `NJClient::Run` as the same
nonzero value. The codes are now named (`ERR_FRAMING`, `ERR_SENDQ_FULL`,
`ERR_TIMEOUT`) and readable with `GetStreamError()`, and `NJClient::Run`
turns whichever one it was handed into a sentence.

| what actually failed | `GetErrorStr()` now says |
|----------------------|--------------------------|
| byte stream no longer parses | the data stream from the server was corrupted and could not be parsed -- the connection itself is still up, so this is not a network dropout, and the session cannot be resumed |
| socket went away | the connection to the server was lost |
| server went quiet (keepalive) | the server stopped responding |
| local send queue overran | the client fell too far behind to keep up with its own audio |

An explanation already in place is never overwritten, so a server-side
rejection still shows the server's own words rather than a client-side guess.

Two front ends needed fixing to make the string reachable, and both fixes are
part of the issue rather than incidental. The curses client labelled it
`Server gave explanation:`, which is wrong for a reason the client produced
itself; and the Dear ImGui client only showed `GetErrorStr()` for
`CANTCONNECT` and `INVALIDAUTH` - never for the `DISCONNECTED` status a
framing failure produces - so the new text would have been invisible in the
default client. The legacy GUI and the Windows client already display it for
any non-OK status.

`ninjam_e2e` now covers both halves, because a test that only checks the
corruption case would pass just as happily if every disconnect said
"corrupted". The server-kill phase asserts the explanation does *not* mention
corruption, and a new phase drops 8 bytes from the middle of every inbound
audio message and asserts that the affected client reports corruption while the
client with an untouched stream stays connected - the fault is per-connection,
not a verdict on the server. The suite reports 34 checks, 0 failures.

**Coverage.** `fuzz/` drives client-to-server bytes into the *server*
(`fuzz/harness.cpp`, and every seed in `gen_corpus.py` is built from
`MSG_CLIENT_UPLOAD_INTERVAL_*`). Nothing there exercises a client decoding a
damaged download, which is why none of this was caught before it was measured.

**Instrumentation note.** The truncation injector is receive-side only, for the
same reason the delay injector is: what a truncation models is what the receiver
ended up with, and the receive side is also the only place a per-participant
value can be applied, since the server pumps every connection on one thread.
A short message is built as a **copy** rather than by resizing in place,
because messages are refcounted and the server hands the same `Net_Message` to
every other participant - shrinking it in place would truncate the upload for
all of them and desynchronise the sender's own byte count.

## 7. Join in progress

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

## 8. Claims the data contradicts

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
can be injected at all. They are a worst case, not a network model. §6 measures
the two finer-grained cases that claim reaches past: a short message, which
costs less than a lost one, and a byte dropped mid-message, which is fatal
rather than degrading.

**d. The interval model is more robust than advertised in the one case that
matters most - a late joiner.** 8.07 s of dead air on join, then bit-level
phase agreement. Nothing in the data suggests a joining client can disturb
the session it joins.

## 9. Measurement caveats, stated rather than smoothed over

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

## 10. What is still open

Each of these has a tracking issue.

- ~~**Where exactly does the slip threshold sit?**~~ **Fully answered, both
  halves.** A pair slips when accumulated relative clock error reaches one
  whole interval, i.e. `ppm_rel = 1e6 * L_s / T_s` (§2.1). Measured boundary
  for 660 s at a 4 s interval is [6000, 8000] ppm against a predicted
  6061 ppm, and nine pairs that started aligned bracket the threshold to
  0.97-1.07 intervals. The second half of the issue - is that one interval, or
  an absolute drift rate - needed the tempo varied, because at 4 s both
  readings predict the same ppm: the ladder repeated at 2 s and 8 s brackets
  the threshold to [3000, 3953] and [12000, 15748] ppm, so it scales with the
  interval and is not a fixed rate (§2.2). The issue's suggested design
  (durations scaling inversely with ppm) was the wrong way round and would have
  measured the same point repeatedly.
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
- ~~**Loss is all-or-nothing per message.** A real lossy link truncates streams
  mid-message. Here a dropped `INTERVAL_WRITE` loses a whole chunk, which is
  the harsher case, so the 72.2% at 10% loss is a lower bound on what
  survives.~~ **Measured, and the ordering is the opposite of what this entry
  assumed.** A dropped message is indeed the harsher case, but not because
  truncation is gentler than expected - because dropping the whole block is
  worse than shortening it. At the same 5%, whole-message loss damaged 47
  intervals against 27 for cutting 2000 B off the tail, and its worst gap
  reached 1.88 intervals where no short write exceeded 0.87 (§6). A short
  message is accepted silently and costs the rest of its own interval; a byte
  dropped mid-message is not a degradation at all but a fatal framing error
  that kills the connection within one 100 ms clock sample. The 72.2% at 10% loss is
  therefore a *pessimistic* bound on what survives a link that merely shortens
  writes, and an optimistic one for anything that drops bytes mid-message.
  [#23](https://github.com/drawmeanelephant/ninjam/issues/23)
- **Some pairs start a whole interval off before any drift accumulates.** This
  turned up while validating §2.1 and is not drift at all. In every run with
  offsets of 3000 ppm or more, several client pairs measure 4020 ms instead of
  8020 ms on their *very first* marker - a full interval of misalignment
  present at t=0, before a millisecond of clock error has built up. It appears
  at 3000 ppm and above and not at 200 ppm or below, and which pairs get it
  is not a simple function of the sign of the offset. §2.2 extends this to the
  other two tempos, where it is present in every run: 3 of 6 pairs at 8 s and
  1-2 of 6 at 2 s, with `2<-1` offset every time, so it is a property of the
  session start-up rather than of the interval or of the injected error. The
  most likely cause is
  the startup transient: a client whose sample counter runs fast crosses an
  extra interval boundary while the session is still coming up, and the
  interval model has no way to express a fractional position, so the error
  lands on the interval grid. This is a *join-time* quantisation and it is not
  in the §2.1 threshold numbers, which use only the pairs that start aligned.  It is worth its own experiment: it means
  a badly-clocked client can be a whole interval out before it has played a
  note, which is a sharper failure than slow drift.
  [#25](https://github.com/drawmeanelephant/ninjam/issues/25)
- ~~**A corrupted byte stream is reported as a bare disconnect, so a framing
  failure is indistinguishable from a dead network.** Found while reviewing the
  #28 work and filed as its own issue afterwards.~~ **Resolved, for the
  diagnosis only.** The status code still cannot say - `1002` covers a socket
  that closed, a stream that stopped parsing, and a peer that fell silent - but
  `GetErrorStr()` now does, and the failure codes behind it are named instead
  of being negative magic numbers. Regression coverage asserts the corruption
  case *and* the dead-socket case it must not be confused with, because a test
  of only the first would pass if every disconnect claimed corruption (§6).
  What is still not fixed is recovery: with no resync marker in the framing,
  a desynchronised stream is unrecoverable and only a reconnect helps.
  [#29](https://github.com/drawmeanelephant/ninjam/issues/29)
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
