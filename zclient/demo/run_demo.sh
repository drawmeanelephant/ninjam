#!/usr/bin/env bash
# zclient end-to-end interop demo — no mocks, everything runs against the
# UNMODIFIED reference ninjamsrv built from this repo's C++ sources.
#
# Scenario 1 (acceptance 1+3): two zclient instances (registered user
#   "alice"/secret and anonymous "bob") exchange >=3 full intervals of audio
#   and chat in both directions; all decoded audio is dumped to WAV and
#   asserted non-silent (RMS >= 0.05), with a silence negative control.
# Scenario 2 (acceptance 2): one zclient + tools/refpeer.cpp, a headless
#   driver of the REFERENCE client core (ninjam/njclient.cpp, same as
#   ninjam/tests/e2e_test.cpp). The reference client must decode zclient's
#   upload (REFPEER RESULT ok=1) and zclient must decode the reference
#   client's tone to a non-silent WAV.
# Scenario 3 (Phase B live audio): zclient --live against the same reference
#   client core. The local device must really open, real microphone frames
#   must reach the upload (and be decoded by the reference client), and the
#   decoded peer mix must really reach the output ring -- measured on the
#   session thread as the samples cross the ring boundary, and mirrored to a
#   WAV so it can be energy-checked. Skipped with a clear message when the
#   machine has no usable device.
#
# Evidence (transcripts, summaries, reports, WAV analysis, unit tests, server
# log) is collected under zclient/demo/evidence/<timestamp>/.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
ZDIR="$REPO/zclient"
SRVBUILD=${NINJAM_SRVBUILD:-/tmp/ninjam-srvbuild}
COREBUILD=${NINJAM_COREBUILD:-/tmp/ninjam-fullbuild}
PORT=${DEMO_PORT:-20491}
RUNTIME=/tmp/zclient-demo
EVDIR="$ZDIR/demo/evidence/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUNTIME" "$EVDIR"

fail() { echo "DEMO FAIL: $*"; exit 1; }

echo "== building zclient (zig 0.16) =="
( cd "$ZDIR" && zig build -Doptimize=ReleaseSafe ) || fail "zig build"
ZCLIENT="$ZDIR/zig-out/bin/zclient"

echo "== unit tests =="
( cd "$ZDIR" && zig build test --summary all ) > "$EVDIR/unit-tests.txt" 2>&1 || {
  cat "$EVDIR/unit-tests.txt"; fail "zig build test"; }
grep -E "test$|tests passed" "$EVDIR/unit-tests.txt" | tail -3 || true

echo "== building reference server from repo C++ (out-of-tree, unmodified) =="
if [ ! -x "$SRVBUILD/bin/ninjamsrv" ]; then
  cmake -S "$REPO" -B "$SRVBUILD" -DCMAKE_BUILD_TYPE=Release \
        -DNINJAM_BUILD_CLIENT=OFF -DNINJAM_BUILD_TESTS=OFF || fail "cmake server"
  cmake --build "$SRVBUILD" -j 8 || fail "build server"
fi
SRV="$SRVBUILD/bin/ninjamsrv"

echo "== building reference client core libs (for refpeer) =="
if [ ! -f "$COREBUILD/libninjam_core.a" ]; then
  cmake -S "$REPO" -B "$COREBUILD" -DCMAKE_BUILD_TYPE=Release \
        -DNINJAM_BUILD_CLIENT=OFF -DNINJAM_BUILD_TESTS=OFF || fail "cmake core"
  cmake --build "$COREBUILD" -j 8 || fail "build core"
fi
if [ ! -x "$RUNTIME/refpeer" ]; then
  VOR=$COREBUILD/_deps/vorbis-src; OGGS=$COREBUILD/_deps/ogg-src
  clang++ -std=c++17 -O2 "$ZDIR/tools/refpeer.cpp" -I"$REPO" \
    -I"$OGGS/include" -I"$VOR/include" -I"$VOR/lib" \
    "$COREBUILD/libninjam_core.a" "$COREBUILD/libninjam_net.a" \
    "$COREBUILD/_deps/vorbis-build/lib/libvorbisenc.a" \
    "$COREBUILD/_deps/vorbis-build/lib/libvorbis.a" \
    "$COREBUILD/_deps/ogg-build/libogg.a" \
    -framework CoreFoundation -framework CoreServices \
    -o "$RUNTIME/refpeer" || fail "build refpeer"
fi

cat > "$RUNTIME/demo.cfg" <<EOF
Port $PORT
MaxUsers 10
MaxChannels 8 2
AnonymousUsers multi
AnonymousUsersCanChat yes
AnonymousMaskIP no
User alice secret C
DefaultTopic "zclient interop demo"
DefaultBPM 100
DefaultBPI 8
SetKeepAlive 3
EOF

pkill -f ninjamsrv 2>/dev/null; sleep 0.3
"$SRV" "$RUNTIME/demo.cfg" -logfile "$EVDIR/server.log" &
SRVPID=$!
sleep 0.7

DUMP1="$RUNTIME/s1-A"; DUMP2="$RUNTIME/s1-B"; DUMP3="$RUNTIME/s2"; DUMP4="$RUNTIME/s3"
rm -rf "$DUMP1" "$DUMP2" "$DUMP3" "$DUMP4"

cleanup() { kill $SRVPID 2>/dev/null; wait $SRVPID 2>/dev/null; }
trap cleanup EXIT

echo "== scenario 1: two zclients on real server =="
"$ZCLIENT" join --host 127.0.0.1:$PORT --user alice --pass secret \
  --duration 26 --channel "zclient-alice" --source tone:440:0.5 \
  --chat "hello from alice (zclient)" --chat-delay 2 \
  --out-dir "$DUMP1" --transcript "$EVDIR/s1-transcript-alice.log" \
  > "$EVDIR/s1-summary-alice.txt" 2>&1 &
A=$!
sleep 1.5
"$ZCLIENT" join --host 127.0.0.1:$PORT --user anonymous:bob --pass x \
  --duration 24 --channel "zclient-bob" --source tone:550:0.4 \
  --chat "hello from bob (zclient anonymous)" --chat-delay 3 \
  --out-dir "$DUMP2" --transcript "$EVDIR/s1-transcript-bob.log" \
  > "$EVDIR/s1-summary-bob.txt" 2>&1 &
B=$!
wait $A $B

echo "== scenario 2: zclient + reference client core =="
"$ZCLIENT" join --host 127.0.0.1:$PORT --user alice --pass secret \
  --duration 30 --channel "zclient-alice" --source tone:440:0.5 \
  --out-dir "$DUMP3" --transcript "$EVDIR/s2-transcript-zclient.log" \
  > "$EVDIR/s2-summary-zclient.txt" 2>&1 &
Z=$!
"$RUNTIME/refpeer" --host 127.0.0.1:$PORT --user anonymous:refpeer --pass x \
  --duration 28 --freq 660 --amp 0.4 --report "$EVDIR/s2-refpeer-report.txt" \
  > "$EVDIR/s2-refpeer.log" 2>&1
R=$?
wait $Z

echo "== scenario 3: zclient --live (real device) + reference client core =="
"$ZCLIENT" join --host 127.0.0.1:$PORT --user alice --pass secret \
  --live --duration 26 --channel "zclient-live" \
  --out-dir "$DUMP4" --transcript "$EVDIR/s3-transcript-zclient.log" \
  --play-wav "$EVDIR/s3-playback-mix.wav" \
  > "$EVDIR/s3-summary-zclient.txt" 2>&1 &
Z=$!
"$RUNTIME/refpeer" --host 127.0.0.1:$PORT --user anonymous:refpeer --pass x \
  --duration 24 --freq 660 --amp 0.2 --report "$EVDIR/s3-refpeer-report.txt" \
  > "$EVDIR/s3-refpeer.log" 2>&1
wait $Z

echo "== assertions =="
# Field extraction from the RESULT line. Anchored on whitespace so that
# "keepalive=3s" in the transcript can never be mistaken for "live=3s".
result_field() {
  grep -oE "(^|[[:space:]])$1=[^ ]*" "$2" | head -1 | sed -E 's/^[[:space:]]*//' | cut -d= -f2
}

for side in alice bob; do
  S="$EVDIR/s1-summary-$side.txt"
  [ "$(result_field ok "$S")" = "true" ] || fail "scenario1 $side: session not ok"
  IU=$(result_field intervals_uploaded "$S"); [ "$IU" -ge 3 ] || fail "scenario1 $side: uploaded=$IU <3"
  ID=$(result_field intervals_downloaded "$S"); [ "$ID" -ge 3 ] || fail "scenario1 $side: downloaded=$ID <3"
  CS=$(result_field chat_sent "$S"); [ "$CS" -ge 1 ] || fail "scenario1 $side: chat_sent=$CS"
  CR=$(result_field chat_received "$S"); [ "$CR" -ge 2 ] || fail "scenario1 $side: chat_received=$CR <2"
  WAVS=$(result_field wav_count "$S"); [ "$WAVS" -ge 1 ] || fail "scenario1 $side: no wavs"
done
grep -q "hello from alice (zclient)" "$EVDIR/s1-transcript-bob.log" || fail "alice's chat never reached bob"
grep -q "hello from bob (zclient anonymous)" "$EVDIR/s1-transcript-alice.log" || fail "bob's chat never reached alice"

grep -q "REFPEER RESULT ok=1" "$EVDIR/s2-refpeer-report.txt" || fail "reference client did not decode zclient audio (see s2-refpeer-report.txt)"
S2="$EVDIR/s2-summary-zclient.txt"
[ "$(result_field ok "$S2")" = "true" ] || fail "scenario2 zclient not ok"
[ "$(result_field intervals_downloaded "$S2")" -ge 3 ] || fail "scenario2: downloaded <3"

# Scenario 3 (live audio). Asserted on signal energy, not on "it ran".
S3="$EVDIR/s3-summary-zclient.txt"
[ "$(result_field ok "$S3")" = "true" ] || fail "scenario3 zclient not ok: $(cat "$S3")"
if [ "$(result_field live "$S3")" != "true" ]; then
  echo "SKIP scenario 3: no audio device available on this machine (see $S3)"
  cp "$EVDIR/s3-transcript-zclient.log" "$EVDIR/s3-transcript-zclient-skipped.log" 2>/dev/null || true
else
  DEVNAME=$(result_field device "$S3" | tr -d '"')
  [ -n "$DEVNAME" ] && [ "$DEVNAME" != "device=" ] || fail "scenario3: no device name"
  CAPF=$(result_field capture_frames "$S3"); [ "$CAPF" -gt 100000 ] || fail "scenario3: capture_frames=$CAPF too low"
  CAPRMS=$(result_field capture_rms "$S3")
  awk -v r="$CAPRMS" 'BEGIN{exit !(r>0)}' || fail "scenario3: microphone energy is zero (rms=$CAPRMS)"
  CAPSTARVED=$(result_field capture_starved "$S3")
  awk -v s="$CAPSTARVED" -v f="$CAPF" 'BEGIN{exit !(s < f*0.05)}' || fail "scenario3: $CAPSTARVED starved frames of $CAPF"
  PLAYF=$(result_field playback_frames "$S3"); [ "$PLAYF" -gt 100000 ] || fail "scenario3: playback_frames=$PLAYF too low"
  PLAYRMS=$(result_field playback_rms "$S3")
  awk -v r="$PLAYRMS" 'BEGIN{exit !(r>0.05)}' || fail "scenario3: playback energy too low (rms=$PLAYRMS)"
  OVER=$(result_field audio_overruns "$S3"); [ "$OVER" -eq 0 ] || fail "scenario3: $OVER audio ring overruns (dropped audio)"
  "$ZCLIENT" check-wav "$EVDIR/s3-playback-mix.wav" --min-rms 0.05 | tee -a "$EVDIR/wav-analysis.txt" \
    || fail "scenario3: playback mix wav below threshold"
  grep -q "REFPEER RESULT ok=1" "$EVDIR/s3-refpeer-report.txt" || fail "scenario3: reference client did not decode the live mic"
  RP=$(grep -o "remote_peak=[0-9.]*" "$EVDIR/s3-refpeer-report.txt" | cut -d= -f2)
  awk -v p="$RP" 'BEGIN{exit !(p>0)}' || fail "scenario3: reference client saw no live-mic energy"
  echo "live audio verified: device=\"$DEVNAME\" capture_rms=$CAPRMS playback_rms=$PLAYRMS refpeer_peak=$RP"
fi

echo "-- WAV energy checks (non-silence assertions) --"
wavchecks=0
for f in "$DUMP1"/*.wav "$DUMP2"/*.wav "$DUMP3"/*.wav "$DUMP4"/*.wav; do
  [ -e "$f" ] || continue
  OUT=$("$ZCLIENT" check-wav "$f" --min-rms 0.05) || fail "WAV below threshold: $f"
  echo "$OUT" | tee -a "$EVDIR/wav-analysis.txt"
  wavchecks=$((wavchecks+1))
done
[ "$wavchecks" -ge 2 ] || fail "expected >=2 decoded WAVs, got $wavchecks"

echo "-- negative control: silence must FAIL the energy check --"
ffmpeg -y -v error -f lavfi -i anullsrc=r=48000:cl=mono -t 3 "$RUNTIME/silence.wav"
if "$ZCLIENT" check-wav "$RUNTIME/silence.wav" --min-rms 0.05 > /dev/null 2>&1; then
  fail "silence passed the energy check (test would be a lie)"
fi
echo "silence correctly rejected (exit $?)"

echo "== evidence -> $EVDIR =="
cp "$EVDIR"/s1-summary-*.txt "$EVDIR"/s2-summary-*.txt "$EVDIR"/s3-summary-*.txt \
   "$EVDIR"/s2-refpeer-report.txt "$EVDIR"/s3-refpeer-report.txt "$EVDIR/" 2>/dev/null || true
if command -v ffmpeg >/dev/null 2>&1; then
  first_wav=$(ls "$DUMP2"/*.wav 2>/dev/null | head -1)
  [ -n "$first_wav" ] && ffmpeg -y -v error -i "$first_wav" -t 5 "$EVDIR/sample-decoded-peer-5s.wav"
  # keep a short excerpt of the live playback mix rather than the full dump
  if [ -f "$EVDIR/s3-playback-mix.wav" ]; then
    ffmpeg -y -v error -i "$EVDIR/s3-playback-mix.wav" -t 5 "$EVDIR/s3-playback-mix-5s.wav"
    rm -f "$EVDIR/s3-playback-mix.wav"
  fi
fi
cp "$RUNTIME"/silence.wav "$EVDIR/negative-control-silence.wav" 2>/dev/null || true
grep -E "Incoming connection|login|accepted|disconnected" "$EVDIR/server.log" | head -20 || true

echo
echo "DEMO PASS"
exit 0
