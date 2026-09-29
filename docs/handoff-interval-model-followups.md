# Handoff: NINJAM interval-model follow-ups (#21, #22, #23)

Written after #20 was answered (branch `exp/drift-threshold`, off the merged
`main` at `c1485787`). This is a brief for an agent picking up the remaining
issues. Read `REPORT.md` first — it is the deliverable and the numbers in it are
all reproducible with one command.

## Where things stand

`REPORT.md` characterises NINJAM's interval model under injected faults. The
harness, the 15 scenarios, the analyzer and the raw logs are all in the repo.
`tools/run_interval_lab.sh` reproduces everything.

The headline results, so you do not have to re-derive them:

- Emission to playback is **two intervals**, not a fixed time: 4020.01 ms at a
  2 s interval, 8020.04 ms at 4 s, 16020.04 ms at 8 s.
- A client does not slide off the grid under clock drift. Its error stays
  pinned to a whole number of intervals and then jumps. The threshold is a
  **product**: a pair slips when accumulated relative clock error reaches one
  whole interval, i.e. `ppm_rel = interval / duration`. Nine pairs that started
  aligned bracket it to 0.97-1.07 intervals.
- Message loss and jitter cost **markers, not alignment**. Alignment stays at
  0.03 ms through 10% loss and 40 ms jitter.
- A late joiner syncs in 8.07 s (2.02 intervals) and lands −0.02 ms off the
  session.

## Facts about the code that are expensive to rediscover

- **The transport is TCP-only.** `Net_Connection` wraps `JNL_IConnection` via
  WDL/jnetlib. There is no UDP path. IP-level packet loss is therefore
  unobservable from inside the process; loss has to be injected at
  `Net_Message` granularity, which is what `ninjam/netcond.{h,cpp}` does.
  Only audio-bearing messages are conditioned (ids `0x83`, `0x84`, `0x04`,
  `0x05` in `ninjam/mpb.h`).
- **There is no timesync message in the protocol.** The server never sends an
  absolute time reference, so alignment can only ever be measured
  client-to-client. If you find yourself wanting a ground truth, it does not
  exist on the wire.
- **The session timeline is the client's own sample counter**
  (`m_session_pos_ms` / `m_session_pos_samples`), advanced one sample per
  sample passed to `AudioProc`, and only after `m_audio_enable=1`. See
  `njclient.cpp:749` (`AudioProc`), `:2475` (`on_new_interval`), `:741`
  (`GetSessionPosition`).
- **The two-interval delay is structural.** The server cannot forward an
  upload until the interval closes, and the client holds audio in a two-deep
  queue: `on_new_interval()` promotes `next_ds[0]`→`ds`, shifts
  `next_ds[1]`→`next_ds[0]`, clears `next_ds[1]`, while
  `MESSAGE_SERVER_DOWNLOAD_INTERVAL_BEGIN` fills `next_ds[0]`
  (`njclient.cpp:2528-2540`).
- **Default config is `DefaultBPM 120` / `DefaultBPI 8`** → a 4 s interval.
  `m_interval_length = (int)(bpi / (bpm/60.0) * srate)`.
- **Markers must be tonal, not broadband.** PRBS markers measure perfectly in
  the self-test (correlation 1.0) and come back at ~0.15 after a real Vorbis
  round trip. Tonal markers survive at 0.707 (= 1/√2 with the √2-normalised
  template). This is documented in `ninjam/tests/interval_probe.h`.
- **`peak` is clamped to 1.0** in the detector (`interval_probe.h:228`). A
  value of exactly `1.0000` means the correlation saturated, not that the
  marker arrived cleanly. It shows up on post-slip rows.

## Things that will waste your time if you do not know them

- **Long runs must be launched detached.** The terminal tool kills
  `nohup ... &` and `disown`. `launchctl submit` survives but *auto-restarts
  the job when it exits*, which has twice wiped completed results, and it does
  not inherit `PATH`. The working answer is `tools/run_detached.py`, which
  double-forks (first fork → child `setsid()` → second fork → grandchild
  reparented to init) and redirects to `--log`:
  `python3 tools/run_detached.py --log FILE -- COMMAND [ARGS...]`.
  A 660 s scenario takes 11 minutes; the four-scenario sweep took ~45.
- **Poll with short `sleep` calls.** Long `run_terminal_command` timeouts
  restart runs and leave orphans.
- **`write_file` needs `instructions`; `str_replace` needs a `replacements`
  array of exact `oldString` pairs.** Heredocs inside
  `run_terminal_command` break on quoting through the shell wrapper — for git
  commit messages, write a message file and use `git commit -F`.
- **Only macOS is available locally.** Linux and Windows correctness is only
  provable through CI.

## The harness bugs already found, so you do not introduce them again

Each of these first produced a plausible but false number:

1. **Message reordering.** Per-message independent jitter sorted by due time
   reorders the TCP stream, scrambling intervals and faking "jitter destroys
   audio" at 37% detection (really 92%). Fixed by clamping due times
   non-decreasing in `Send()` order via `m_lastdue`, which is what TCP
   actually does.
2. **Correlation shadows.** A Hann template aligned half a burst late still
   correlates ~0.5, so every marker threw a duplicate ~1 burst-length behind
   itself. Dedup window is now `4.0*burst`; the analyzer dedups (strongest hit
   wins) and reports a `shadow rows` column.
3. **Phase wrap units.** `interval_len` in the clock CSV is in **samples**
   (192000) but the phase is in **ms**, so the wrap was a no-op.
4. **Detection-rate math.** The denominator double-counted listener
   emissions, printing 198.8%/287.2%. Should be
   `sum(emitted) - emitted[l]`.

There is also a latent analyzer crash that was fixed on the drift branch and
may still be live on `main`: `s.align[s.ks[-1]]` raises `KeyError` when the
last marker was heard by only one pair.

## Platform build gotchas (both already fixed, do not "tidy" them)

- `ninjam/netcond.cpp` must include `<stdlib.h>` **first**, before
  `netcond.h`/`mpb.h`. The chain is `mpb.h` → `netmsg.h` → `WDL/queue.h` →
  `heapbuf.h`, and `heapbuf` uses `malloc`/`free`/`realloc` without including
  `stdlib.h`. glibc does not have them in scope; macOS and MSVC pull stdlib in
  transitively, so it is invisible locally and fatal on Ubuntu. Same class as
  existing commit `f32859b7`. Verify with
  `clang++ -H -fsyntax-only` and check the include depths, not by eye.
- `ninjam/tests/interval_lab.cpp` needs the `lab_mkdir()` helper (matching
  `ui_snapshot.cpp`: `_mkdir`, no mode argument), `NOMINMAX` before
  `<windows.h>`, and the one `std::min` call site rewritten as an explicit
  comparison so it does not depend on `NOMINMAX` holding for every header in
  the translation unit.

## The three issues

### #21 — attribute the constant ~20 ms residual

The emission-to-playback delay is 2 intervals plus a constant **20.01–20.04 ms**
that does not move when the interval length changes by 4x. It is currently
attributed to codec and loopback latency, which is a guess.

Cheap discriminator: move `--mark-len` or the lab chunk size and see whether the
residual follows. If it is harness-side, the true interval delay is exactly two
intervals and the constant is an artefact of the measuring apparatus. Either
answer is worth having; the current ambiguity is the problem.

### #22 — measure under real round-trip latency

All clients are in one process on one machine, so inter-client skew here is
protocol behaviour, not network behaviour. Real deployments add RTT that the
interval model has to absorb.

The injector already has the right semantics — due times are clamped
non-decreasing, so it will not reorder the stream — so this is a **scenario
axis, not new machinery**. Add latency to `scenarios()` in
`tools/run_interval_lab.sh` and run it.

Keep the caveat honest: the 40 ms jitter result *hints* that added latency
displaces delivery without moving playout, but that was latency **variation**,
not a latency **offset**, and 40 ms is not 200 ms. Do not overstate it.

### #23 — model mid-message stream truncation

Loss is currently all-or-nothing per `Net_Message`. A real lossy link truncates
streams mid-message. This is a **measurement gap, not a known bug** — the
harsher per-message case is already measured, so mid-message truncation is the
more realistic one and the 72.2% survival at 10% loss is a lower bound.

Check `fuzz/` (from #11) before writing new parser coverage; a lot of the
malformed-input surface may already be covered there.

## Not filed, but worth knowing

- **Some client pairs start a whole interval off before any drift
  accumulates.** In every run with offsets ≥3000 ppm, several pairs measure
  4020 ms instead of 8020 ms on their *first* marker. It appears at 3000 ppm
  and above, not at 200 ppm or below, and which pairs get it is not a simple
  function of the sign of the offset. Likely a startup transient where a fast
  sample counter crosses an extra interval boundary while the session is coming
  up, and the interval model has no way to express a fractional position. This
  is a **join-time** quantisation and it is a sharper failure than slow drift: a
  badly-clocked client can be a whole interval out before playing a note.
  Deserves its own issue and experiment. It is excluded from the §2.1 threshold
  numbers, which use only pairs that start aligned; the two affected pairs need
  two intervals of accumulated error to show a transition and cross at
  1.99–2.08 iv, exactly as the same one-interval rule predicts.
- **A single-marker slip reading is only as good as the gap before it.**
  Marker gaps in these runs are not uniformly 12 s: the median is 12.0 s but
  the maximum is 87.2 s, because a pair that is slipping also drops markers.
  One pair reads 1.19 iv instead of ~1.03 purely because markers k=21..24 went
  missing and the bracket spans 51.6 s. Always bracket the threshold from the
  last aligned marker as well as the first slipped one, and expect outliers.
  Related: the offset is **not monotonic** in accumulated drift — three pairs
  cross the boundary and later return to where they started, so "slips" is not
  a one-way ratchet and only the first crossing is a clean measurement.
- **Per-client bias is not separated from real clock difference.** Every
  scenario uses a symmetric `0:+X:-X` triple. An asymmetric set such as
  `0:+37:-211` would separate them. One-line change.

## Working agreement

Own your branch, open your own PR, and do not touch `results/` for scenarios
you are not running — the raw logs are checked in and the analyzer reads every
directory it finds. Flag explicitly in the writeup any claim your data
contradicts, including claims this report makes.
