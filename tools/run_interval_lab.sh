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

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build-interval-lab"
OUT_DIR="$ROOT/results"
QUICK=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --build-dir)  BUILD_DIR="$2"; shift 2 ;;
    --out)        OUT_DIR="$2"; shift 2 ;;
    --quick)      QUICK=1; shift ;;
    --only)       ONLY="$2"; shift 2 ;;
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
else
  # the report's headline runs are 11 minutes, comfortably over the
  # "10+ minute" requirement
  DRIFT_SECS=660
  LOSS_SECS=150
  JOIN_SECS=300
fi

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
loss1|$LOSS_SECS||3|--up-loss=1 --down-loss=1
loss5|$LOSS_SECS||3|--up-loss=5 --down-loss=5
loss10|$LOSS_SECS||3|--up-loss=10 --down-loss=10
jitter|$LOSS_SECS||3|--up-jitter=40 --down-jitter=40
latejoin|$JOIN_SECS||3|--late-join=120
interval2s|$LOSS_SECS||3|--bpi=4 --mark-period=12
interval8s|$LOSS_SECS||3|--bpi=16 --mark-period=20
EOF
}

if [ "$ONLY" = "__list__" ]; then
  scenarios | cut -d'|' -f1
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
scenarios | while IFS='|' read -r name secs ppm nclients extra; do
  [ -n "$name" ] || continue
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
echo
echo "raw logs:   $OUT_DIR/<scenario>/*.csv"
echo "tables:     $OUT_DIR/tables.md"
