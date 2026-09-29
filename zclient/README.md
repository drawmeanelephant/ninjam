# zclient — a NINJAM client in Zig

A from-scratch NINJAM client that speaks the frozen wire protocol to an
**unmodified** reference `ninjamsrv`, with real live audio in and out. Nothing
under `ninjam/` is touched; the protocol is implemented from
[`docs/PROTOCOL.md`](../docs/PROTOCOL.md) with the C++ client as ground truth
where the spec is ambiguous.

* Zig 0.16.0, no package manager, no ecosystems.
* Vendored dependencies, source only: `stb_vorbis.c` (decode),
  `libogg` + `libvorbis` (encode), `miniaudio.h` (live device).
* Statically linked; no runtime dependency beyond system libc / system audio
  frameworks.

## Status

| Phase | What it is | State |
| --- | --- | --- |
| **A** | Full protocol interop: transport, handshake, auth, interval engine, Ogg Vorbis decode of peers + encode of the local channel, chat, keepalives. Decoded peer audio is dumped to WAV and energy-asserted. | done, verified against the reference server |
| **B** | Live audio: capture from the local device feeds the uplink, the decoded peer mix plays out of it, both via a single miniaudio duplex device. | done, verified against the reference server with a real Core Audio device |

Both phases are exercised by `demo/run_demo.sh` against a real server; see
[Verification](#verification).

## Build

```sh
cd zclient
zig build -Doptimize=ReleaseSafe      # -> zig-out/bin/zclient
zig build test                         # unit tests (protocol, vorbis, wav, rings)
```

Build options:

| Option | Default | Meaning |
| --- | --- | --- |
| `-Dlive=true\|false` | `true` on macOS, `false` elsewhere | compile Phase B live audio (miniaudio). `false` builds a client with no audio-device dependency at all. |

Targets:

```sh
# native (macOS): libSystem + CoreAudio/AudioToolbox/AudioUnit/CoreFoundation/CoreServices
zig build -Doptimize=ReleaseSafe

# fully static Linux binary, no miniaudio:
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe -Dlive=false
```

## Run

```sh
# join a session with a synthetic source (Phase A)
zig-out/bin/zclient join --host 127.0.0.1:2049 --user alice --pass secret \
  --source tone:440:0.5 --duration 30 --out-dir dump --chat "hello"

# join with the real microphone and speakers (Phase B)
zig-out/bin/zclient join --host 127.0.0.1:2049 --user alice --pass secret \
  --live --duration 30 --out-dir dump --play-wav playback-mix.wav

# energy-check a WAV; exits non-zero on silence
zig-out/bin/zclient check-wav playback-mix.wav --min-rms 0.05
```

`--help` lists everything. The client prints one machine-readable `RESULT`
line at the end of a session:

```
RESULT ok=true intervals_uploaded=4 intervals_downloaded=4 wav_count=1
       live=true device="MacBook Pro Speakers" dev_srate=48000
       capture_frames=1234852 capture_starved=4839 capture_rms=0.004068
       playback_frames=921600 playback_rms=0.142371 audio_overruns=0 ...
```

Every audio number there is measured on the session thread as samples cross the
ring boundary, so a silent device cannot fake a passing run. A full transcript
(protocol messages, timings, per-interval decode results) is written to
`--transcript`.

## Maintaining this

The short version: **this is a protocol conformance client, not a product.** It
exists to be a second independent implementation of the frozen protocol, so the
spec and the server can be checked against something that was not written by
the same hand. It is not a supported NINJAM client, has no UI, and is not
intended to grow into one.

What that means for ongoing cost:

| Surface | Cost | Notes |
| --- | --- | --- |
| `src/` (Zig, ~3.5k lines) | low | Only changes if the protocol changes. Zig 0.16 churn is the main risk; it is pinned and CI would show it. |
| `vendor/` | very low | Fully reproducible. `vendor/refresh-vendor.sh --check` (run in CI) proves the tree still matches the pinned upstream downloads. Bumping a dependency is editing two lines in that script and rerunning it. |
| `demo/run_demo.sh` | low, opt-in | Needs cmake, a C++ toolchain and network on first run (the reference client's ogg/vorbis come via `FetchContent`). It is not run in CI and is not a gate. |
| `tools/refpeer.cpp` | low | Links the in-tree `libninjam_core.a` / `libninjam_net.a`, so it tracks this repo's CMake targets. If those targets move, this file is the thing to fix — and nothing else depends on it. |

What is explicitly *not* maintained: multi-device input, per-channel sources,
Linux live audio (the code path needs ALSA headers, but no machine here has
been able to exercise it), and anything resembling a mixer or UI.

Things that will break it, and what to do:

* **A protocol change.** Update `docs/PROTOCOL.md` first, then `src/proto.zig`;
  the unit tests are byte-golden against the spec's worked transcript.
* **A new Zig release.** `build.zig`, `std.Io` usage. CI is the tripwire.
* **A CVE in libvorbis/libogg/stb/miniaudio.** Change the pin in
  `refresh-vendor.sh`, rerun it, `--check`, tests, demo.
* **A server behaviour change.** `demo/run_demo.sh` should fail, with the
  transcript showing where.

Nothing here is on the critical path for the server or the reference client.
The worst case if it bit-rotted is that CI goes red on a directory nobody
depends on.

## Continuous integration

`.github/workflows/ci.yml` has a `zclient` job alongside the C++ matrix: it
verifies the vendored sources against their upstream pins, installs Zig 0.16.0,
runs `zig build test`, builds the release binary, smoke-tests it against a
committed evidence WAV, and on Linux cross-builds a static musl binary and
asserts it is statically linked. macOS exercises the live-audio build
(miniaudio + Core Audio); Linux builds without it (`-Dlive=false` by default
there), so no ALSA headers are needed in CI.

## Layout

```
src/
  main.zig      CLI
  net.zig       TCP + 5-byte framing (type + u32le size, <=16384)
  proto.zig     every message type in and out
  auth.zig      double-SHA1 auth reply
  session.zig   login FSM, interval engine, download decode, chat, live wiring
  audio.zig     Phase B: miniaudio shim + ring buffers + rate conversion
  vorbis.zig    stb_vorbis decode, libvorbis encode
  wav.zig       WAV writer + RMS/peak analysis
  log.zig       transcript writer
vendor/
  miniaudio.h + miniaudio_impl.c   live device (one C TU behind a small shim)
  stb_vorbis.c                     Vorbis decoder
  libogg/, libvorbis/              Vorbis encoder
tools/refpeer.cpp  headless driver of the REFERENCE client core
demo/run_demo.sh  end-to-end scenarios + evidence collection
```

### Why miniaudio is behind a C shim

`miniaudio.h` does not survive `translate-c`, so `audio.zig` never
`@cImport`s it. The header is compiled once in `vendor/miniaudio_impl.c` and
exposes six functions (`zc_device_open/close/sample_rate/name/frames_seen`,
`zc_backend_name`, `zc_probe`); the real-time data path is one C function
pointer handed to the device callback. Ring buffers live in Zig, guarded by
pthreads so the audio thread can block rather than spin.

### Live audio notes

* The device opens at the session sample rate; if the backend hands back a
  different rate, a linear resampler bridges the gap (CoreAudio on macOS
  accepts 48 kHz on 44.1 kHz hardware, so this is a fallback).
* The capture ring is a jitter buffer: the device thread runs ~100 ms ahead of
  the session thread, and the rest of its capacity absorbs session stalls. A
  run reports `capture_starved` (frames that had to be zero-filled) so any
  regression shows up as a number instead of a mystery.
* The capture pre-roll between opening the device and the server's first
  BPM/BPI message (~3-4 s) is discarded: uploading it would push audio several
  seconds stale.
* The playback ring holds 30 s because a decoded NINJAM interval arrives in a
  single burst (60 bpm x 16 bpi is already 16 s of audio).
* With multiple `--channel`s, the capture block is pulled once per encode step
  and shared (`session.encodeBlockFor`). Pulling per channel would hand each
  channel a different slice of the device ring and drift them apart in time; a
  unit test pins that invariant.
* Live audio is developed and verified on macOS/Core Audio. On Linux the same
  code path needs ALSA development headers at build time (`-Dlive=true`);
  `-Dlive=false` builds everywhere and stays fully static.

## Verification

`demo/run_demo.sh` builds the **unmodified** reference server and the reference
client core out of tree, then runs four scenarios against a real server and
writes transcripts, summaries, unit-test output, WAV analysis and the server log
to `demo/evidence/<timestamp>/`. It asserts signal energy everywhere and keeps
a silence negative control, so a run that passes on silence cannot pass.

1. **Two zclients** on a real server: mutual auth, >=3 full intervals each way,
   chat sent *and* received, every decoded WAV above an RMS floor.
2. **Interop with the reference client core** (`tools/refpeer.cpp`, built from
   this repo's own `ninjam/njclient.cpp`): audio flows both directions, and the
   reference side asserts the energy it decoded.
3. **Live audio**: a real Core Audio device opens, real microphone frames reach
   the upload (the reference client decodes them), and the decoded peer mix
   reaches the output ring — mirrored to `--play-wav` and energy-checked.
4. **Multi-channel live**: two local channels off the same device. Both must
   stream, and the reference client must decode real audio on *both* — the
   end-to-end check that they stay aligned rather than drifting apart.

```sh
bash demo/run_demo.sh
```

Each run writes a timestamped directory; only the newest one is kept under
version control, and the committed WAVs are 1 s excerpts (plus the silence
negative control) — enough to show the audio was real without carrying
recordings in the repo.

## Limitations

* Multiple local channels share one capture signal; there is no per-channel
  source selection (a second mic would need a second device or a channel mixer).
* No metronome/beat clock UI, no recording, no chat UI: this is a protocol
  client with a CLI, not a DAW.
* Live output is a mono sum of every subscribed peer, like the reference
  client; there is no per-peer gain.
* Live audio is verified on macOS/Core Audio only.
