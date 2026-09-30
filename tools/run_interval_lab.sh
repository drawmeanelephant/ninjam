#!/usr/bin/env bash
#
# NINJAM interval-model experiment.
#
# One command reproduces everything in REPORT.md:
#
#     tools/run_interval_lab.sh
#
# Configures and builds the server, the client core and the lab harness,
# checks the marker detector against synthetic signals, then runs the full
# scenario matrix and writes raw logs under results/ and tables to
# results/tables.md.
#
# Options:
#   --build-dir DIR   build directory (default: build-interval-lab)
#   --out DIR         results directory (default: results)
#   --quick           short runs (2 min drift, 40 s everything else); for
#                     checking the pipeline, NOT for the numbers in REPORT.md
#   --only NAME[,NAME] run only the named scenarios
#   --list            list scenario names and exit
#
#   --probes          also run the issue #25 probe lane (9 short runs, ~18 min
#                     of wall clock on top of the core matrix). They are off by
#                     default because they do not feed any number in REPORT.md
#                     except the onset bracket in 2.3, and adding them to the
#                     default run would slow down every other reproduction for
#                     the sake of one table. `--probes` reproduces them;
#                     `--only=NAME` still works against either lane.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build-interval-lab"
OUT_DIR="$ROOT/results"
QUICK=0
ONLY=""
PROBES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --build-dir)  BUILD_DIR="$2"; shift 2 ;;
    --out)        OUT_DIR="$2"; shift 2 ;;
    --quick)      QUICK=1; shift ;;
    --only)       ONLY="$2"; shift 2 ;;
    --probes)     PROBES=1; shift ;;
    --list)       QUICK=0; ONLY="__list__"; shift ;;
    --build-dir=*) BUILD_DIR="${1#*=}"; shift ;;
    --out=*)       OUT_DIR="${1#*=}"; shift ;;
    --only=*)      ONLY="${1#*=}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$QUICK" = "1" ]; then
  DRIFT_SECS=120
  LOSS_SECS=40
  JOIN_SECS=120
  RESID_SECS=60
else
  # the report's headline runs are 11 minutes, comfortably over the
  # "10+ minute" requirement
  DRIFT_SECS=660
  LOSS_SECS=150
  JOIN_SECS=300
  # residual attribution only needs enough markers to take a median, not a
  # long session: the quantity is a constant, not an accumulation
  RESID_SECS=200
fi

# TRUNC_SECS is the same length: what a truncated write costs is a fraction of
# one interval, but counting the damage needs enough events to have a
# distribution, and events arrive at about one per message per client.
TRUNC_SECS="$RESID_SECS"

# PROBE_SECS is much shorter. These runs answer a question about the FIRST
# interval, not about an accumulation, so they need a handful of markers and
# nothing more -- the quantity they measure is latched at marker 1 and then
# only changes when the accumulated drift crosses a whole interval, which at
# these rates would take longer than the whole run.
PROBE_SECS=120

# --- scenarios -------------------------------------------------------------
# name | duration | ppm list | clients | extra options
#
# drift8000 is not a realistic crystal (8000 ppm = 0.8%); it is here to find
# the point at which accumulated drift is large enough to move a marker into
# the neighbouring interval, which is where the interval model should break.
#
# drift3000/4000/6000/12000 bisect that threshold (issue #20). A client does
# not slide off the grid -- its error stays pinned to a whole number of
# intervals and then jumps -- so the threshold is a PRODUCT of clock error and
# time, not a rate: a pair slips when ppm_rel * t reaches one interval. Holding
# the run length fixed and stepping the ppm therefore walks the accumulated
# error across the threshold, and the slip/no-slip boundary should land at
#     ppm_threshold = interval_ms / duration_s
# For the 660 s runs at a 4 s interval that is 6061 ppm relative. Each rung is
# labelled with the interval fraction it is predicted to accumulate:
#   3000 -> 0.50 iv   4000 -> 0.66 iv   6000 -> 0.99 iv   8000 -> 1.32 iv
#   12000 -> 1.98 iv (two whole intervals)
# Each run also contains a pair at twice the nominal ppm (0:+X:-X makes the
# 1<-2 pair 2X), so one run yields two rungs of the ladder for free.
# NOTE the durations do NOT need to scale inversely with ppm, as issue #20
# assumed: that would hold accumulated drift constant and measure the same
# point repeatedly instead of finding the boundary.
# interval2s / interval8s vary only the tempo, to test whether the observed
# emission-to-playback delay is a fixed number of intervals or a fixed time.
# Their mark period has to grow with the interval: the lab refuses a mark
# period below 2.5x the interval, because two consecutive markers closer
# than that cannot be told apart from a single detection.
#
# The threshold depends on the interval (issue #20, second half). The ladder
# above is entirely at a 4 s interval, where the two candidate laws predict
# the SAME number:
#   (a) one whole interval of accumulated error  ->  ppm = L / T  = 6061
#   (b) an absolute relative clock error         ->  ppm = 6061, always
# so the 4 s runs cannot tell them apart. These rungs repeat the ladder at
# 2 s and 8 s, where (a) predicts 3030 and 12121 ppm and (b) still predicts
# 6061. Rungs are chosen so that (a) and (b) disagree about whether the pair
# slips at all:
#   2 s:  2000 -> 0.61 iv (1<-2 at 4000 -> 1.21 iv)
#         3000 -> 0.91 iv (1<-2 at 6000 -> 1.82 iv)
#         4000 -> 1.21 iv
#   8 s:  6000 -> 0.99 iv (1<-2 at 12000 -> 1.98 iv)
#         8000 -> 1.32 iv
#         12000 -> 1.98 iv
# A slip at 4000 ppm/2 s, or at 12000 ppm/8 s, is a slip (b) forbids. A pair
# that slips at 1.2 iv but not at 1.0 iv, in every tempo, is (a). The
# threshold in ppm then scales with the interval and nothing else does.
# The mark period is kept at 12 s for the 2 s runs (6x the interval, the same
# absolute grid as the 4 s ladder) and 20 s for the 8 s runs, which is the
# 2.5x minimum the lab enforces and the tempo interval8s already uses.
#
# Residual attribution (issue #21). The emission-to-playback delay is two
# intervals plus a constant ~20 ms that does not move when the interval
# length changes 4x. Two candidate causes:
#   (a) the DETECTOR reports the centre of the correlation window while the
#       marker is emitted at its START, biasing the measurement by half the
#       burst: (mark_len-1)/2 samples = 19.99 ms at the default 1920;
#   (b) real codec or loopback latency, which would be independent of
#       mark_len.
# Varying mark_len separates them: under (a) the residual scales with it,
# under (b) it does not. mark960 and mark3840 bracket the default, and
# mark3840iv2s combines the long burst with a short interval.
#
# Real round-trip latency (issue #22). --client-delay adds a one-way latency
# per client, applied in BOTH directions (client->server AND server->client),
# which is what a real deployment's RTT looks like to the interval model. The
# rtt-spread scenario puts three clients at 0 / +50 / +200 ms; rtt100 gives
# every client the same +100 ms, to separate "does added latency move
# anything" from "does a latency SPREAD between clients move anything".
# Prediction under test: the interval clock is driven by each client's own
# sample counter, not by message arrival, so added latency should displace
# delivery time without moving playout time -- delays rise by the injected
# amount, alignment stays put.
#
# MEASURED: the second half holds, the first does not. Neither the delay
# column nor the alignment figures move at all; the rtt rows are
# indistinguishable from baseline in every table. The two-interval pipeline
# absorbs the latency outright instead of merely displacing delivery time,
# because an upload arriving 200 ms into its own interval and one arriving
# 200 ms + RTT late both make the same interval close. See REPORT.md section 5.
scenarios() {
  cat <<EOF
baseline|$DRIFT_SECS||3
drift50|$DRIFT_SECS|0:50:-50|3
drift200|$DRIFT_SECS|0:200:-200|3
drift8000|$DRIFT_SECS|0:8000:-8000|3
drift3000|$DRIFT_SECS|0:3000:-3000|3
drift4000|$DRIFT_SECS|0:4000:-4000|3
drift6000|$DRIFT_SECS|0:6000:-6000|3
drift12000|$DRIFT_SECS|0:12000:-12000|3
drift2000iv2s|$DRIFT_SECS|0:2000:-2000|3|--bpi=4
drift3000iv2s|$DRIFT_SECS|0:3000:-3000|3|--bpi=4
drift4000iv2s|$DRIFT_SECS|0:4000:-4000|3|--bpi=4
drift6000iv8s|$DRIFT_SECS|0:6000:-6000|3|--bpi=16 --mark-period=20
drift8000iv8s|$DRIFT_SECS|0:8000:-8000|3|--bpi=16 --mark-period=20
drift12000iv8s|$DRIFT_SECS|0:12000:-12000|3|--bpi=16 --mark-period=20
loss1|$LOSS_SECS||3|--up-loss=1 --down-loss=1
loss5|$LOSS_SECS||3|--up-loss=5 --down-loss=5
loss10|$LOSS_SECS||3|--up-loss=10 --down-loss=10
jitter|$LOSS_SECS||3|--up-jitter=40 --down-jitter=40
latejoin|$JOIN_SECS||3|--late-join=120
interval2s|$LOSS_SECS||3|--bpi=4 --mark-period=12
interval8s|$LOSS_SECS||3|--bpi=16 --mark-period=20
mark960|$RESID_SECS||3|--mark-len=960
mark3840|$RESID_SECS||3|--mark-len=3840
mark3840iv2s|$RESID_SECS||3|--mark-len=3840 --bpi=4 --mark-period=12
rtt-spread|$RESID_SECS||3|--client-delay=0:50:200
rtt100|$RESID_SECS||3|--client-delay=100:100:100
# Truncation (issue #23). A whole audio message going missing is only one way
# a write can fail to arrive intact; the other is that it arrives SHORT, with
# the tail of its payload gone, which the protocol accepts silently because a
# message's payload length is whatever the message says it is. These run at a
# 2 s interval with a 6.5 s mark period, so 6500 mod 2000 = 500 puts markers at
# four distinct offsets inside an interval and the loss can be attributed to
# the interval it happened in rather than to a whole run.
#
# --steady puts a quiet 250 Hz tone on every channel, so a remote channel's
# decoded level is a continuous measure of whether its audio is flowing: a
# truncated stream shows up as a measured gap with a start and an end, not
# only as a marker that failed to arrive. truncbase is the control and differs
# from every other row here only in tempo, mark period and that tone.
#
# truncdown truncates the tail of messages a client RECEIVES, so the damage
# should be confined to that one client. truncup truncates on the server's
# receive thread instead, so one damaged upload is forwarded to everyone else
# and the loss should show up on two clients at once. truncloss is the
# comparison the issue actually asks for: the same number of messages lost
# whole, which should cost a fraction of an interval each rather than the
# rest of one.
#
# desync is the case the framing cannot survive at all: 8 bytes vanish from
# the middle of a message body, so every length after that point is read from
# the wrong offset. desyncup does the same to the uplink.
truncbase|$TRUNC_SECS||3|--bpi=4 --mark-period=6.5 --steady=0.05
truncdown|$TRUNC_SECS||3|--bpi=4 --mark-period=6.5 --steady=0.05 --trunc-pct=5 --trunc-bytes=2000
truncup|$TRUNC_SECS||3|--bpi=4 --mark-period=6.5 --steady=0.05 --srv-trunc-pct=5 --srv-trunc-bytes=2000
truncloss|$TRUNC_SECS||3|--bpi=4 --mark-period=6.5 --steady=0.05 --down-loss=5
desync|$TRUNC_SECS||3|--bpi=4 --mark-period=6.5 --steady=0.05 --desync-pct=3 --desync-bytes=8
desyncup|$TRUNC_SECS||3|--bpi=4 --mark-period=6.5 --steady=0.05 --srv-desync-pct=3 --srv-desync-bytes=8
EOF
}

# The #25 probe lane, opt-in via --probes rather than part of the default
# matrix. Some pairs measure one whole interval less than the two-interval
# pipeline on their very first marker, before any drift has accumulated.
# Three hypotheses: a startup transient, the interval grid being unable to
# express a fractional position, or an artefact of the harness pacing samples
# at (1 + ppm*1e-6). The rows below separate them, and they are short because
# they are all decided at marker 1.
#
# startoff1s / startoff2s / startoff4s inject ZERO clock error of any kind.
# --start-offset holds one client's audio start back by a fixed 1, 2 and 4
# seconds, which moves its session position 0 -- and with it the phase of its
# whole interval grid against the server's -- later in wall time, without
# changing how fast any grid is traversed. If a pure phase offset with no rate
# anywhere reproduces the one-interval offset, it is not about drift. That the
# 2 s and 4 s rows answer identically to the 1 s row is the point: only the
# sign matters, because a phase shift is taken modulo the interval.
#
# ramp3000 is the drift3000 ladder with the offset dialled in from 0 over the
# whole run. A startup transient would have to happen while the offset is
# still zero, so if ramping removes the effect it cannot be a transient.
#
# ppm500 .. ppm2500 bracket the onset in ppm. Under the grid reading the
# onset is where the emitter's grid phase leads the listener's by enough to
# beat the pipeline's own close-to-decode latency, which is a prediction
# about the size of the lead rather than about startup.
probe_scenarios() {
  cat <<EOF
startoff1s|$PROBE_SECS||3|--start-offset=0:0:1
startoff2s|$PROBE_SECS||3|--start-offset=0:0:2
startoff4s|$PROBE_SECS||3|--start-offset=0:0:4
ramp3000|$PROBE_SECS|0:3000:-3000|3|--ppm-ramp=$PROBE_SECS
ppm500|$PROBE_SECS|0:500:-500|3|
ppm1000|$PROBE_SECS|0:1000:-1000|3|
ppm1500|$PROBE_SECS|0:1500:-1500|3|
ppm2000|$PROBE_SECS|0:2000:-2000|3|
ppm2500|$PROBE_SECS|0:2500:-2500|3|
EOF
}

# What this invocation actually runs: the core matrix, plus the probe lane if
# asked for. Every consumer below goes through here rather than through
# scenarios() directly, so `--list` and the run loop cannot drift apart.
all_scenarios() {
  scenarios
  # An explicit --only=NAME naming a probe should work without also having to
  # pass --probes; the only-filter drops the rest, so emitting the probe lane
  # there costs nothing. --list is excluded because --list with no --only is
  # how you ask what the default matrix contains.
  if [ "$PROBES" = "1" ] || { [ -n "$ONLY" ] && [ "$ONLY" != "__list__" ]; }; then
    probe_scenarios
  fi
}

if [ "$ONLY" = "__list__" ]; then
  all_scenarios | sed -n 's/^\([^#|][^|]*\)|.*/\1/p'
  exit 0
fi

# --- build -----------------------------------------------------------------
echo "== configuring and building in $BUILD_DIR"
cmake -S "$ROOT" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DNINJAM_BUILD_SERVER=ON \
  -DNINJAM_BUILD_CLIENT=OFF \
  -DNINJAM_BUILD_TESTS=ON >/dev/null
cmake --build "$BUILD_DIR" --target ninjamsrv ninjam_interval_lab ninjam_probe_selftest

LAB="$BUILD_DIR/bin/ninjam_interval_lab"
SRV="$BUILD_DIR/bin/ninjamsrv"

# --- validate the measuring instrument first -------------------------------
echo "== detector self-test"
"$BUILD_DIR/bin/ninjam_probe_selftest"
if [ $? -ne 0 ]; then
  echo "detector self-test failed; refusing to produce numbers" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# --- run the matrix --------------------------------------------------------
echo "== running scenarios into $OUT_DIR"
all_scenarios | while IFS='|' read -r name secs ppm nclients extra; do
  # The scenario list is a heredoc of commentary and one pipe-separated record
  # per line. Blank and comment lines have to be dropped here: without this the
  # unfiltered run -- the documented "one command reproduces everything" --
  # feeds the commentary to the lab as a scenario called "# name " with a
  # duration of "duration", and dies on the first line under `set -e`.
  case "$name" in
    ''|\#*) continue ;;
  esac
  if [ -n "$ONLY" ]; then
    case ",$ONLY," in *",$name,"*) ;; *) continue ;; esac
  fi

  work="$OUT_DIR/$name"
  rm -rf "$work"
  mkdir -p "$work"

  args=(--srv="$SRV" --out="$work" --tag="$name"
        --clients="$nclients" --duration="$secs" --mark-period=12)
  [ -n "$ppm" ] && args+=(--ppm="$ppm")
  # shellcheck disable=SC2206
  [ -n "$extra" ] && args+=($extra)

  echo "-- $name (${secs}s, ${nclients} clients ${ppm:+(ppm $ppm)} ${extra})"
  "$LAB" "${args[@]}" | tee "$work/run.log"

  # drop the per-client scratch directories (NJClient caches remote audio
  # there); the CSVs and the server log are what we keep
  rm -rf "$work"/client*/
done

# --- tables ----------------------------------------------------------------
echo "== building tables"
python3 "$ROOT/tools/analyze_interval_lab.py" "$OUT_DIR" > "$OUT_DIR/tables.md"

# The report quotes the slip-threshold brackets in prose. Check them against
# the tables we just built, so the two cannot drift apart.
if [ -f "$ROOT/REPORT.md" ]; then
  echo "== verifying REPORT.md against the tables"
  python3 "$ROOT/tools/verify_report_brackets.py" "$OUT_DIR"
fi
echo
echo "raw logs:   $OUT_DIR/<scenario>/*.csv"
echo "tables:     $OUT_DIR/tables.md"
