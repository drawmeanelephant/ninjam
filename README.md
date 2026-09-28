# NINJAM

NINJAM is the network jam session system from www.ninjam.com: everyone plays in
sync by broadcasting audio in compressed interval chunks, so latency becomes
part of the music instead of a problem.

This tree contains the **server**, the **client core** and a **new
cross-platform GUI client**, all buildable with one CMake build. The wire
protocol is unchanged, so everything here interoperates with existing NINJAM
servers and clients.

## Building

Requirements: CMake ≥ 3.20 and a C++17 compiler. Everything else
(libogg/libvorbis, GLFW, Dear ImGui, miniaudio) is fetched automatically at
configure time. On Linux, GLFW needs the usual X11/OpenGL dev packages
(`libgl1-mesa-dev xorg-dev` on Debian/Ubuntu).

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build
```

Executables land in `build/bin/`:

| binary | what |
|---|---|
| `ninjamsrv` | the NINJAM server |
| `ninjam-client` | the GUI jam client |
| `ninjam_tests` | unit tests (run via CTest) |

CMake options: `NINJAM_BUILD_SERVER`, `NINJAM_BUILD_CLIENT`,
`NINJAM_BUILD_TESTS` (all default ON).

## Running a server

```sh
cd ninjam/server
../../build/bin/ninjamsrv example.cfg -logfile server.log
```

See `ninjam/server/example.cfg` for the configuration reference (ports, user
accounts, ACLs, anonymous access, recording archives). Users named
`anonymous` or `anonymous:<tag>` join through the anonymous policy.

## Running the client

```sh
./build/bin/ninjam-client [--host host[:port]] [--user name] [--pass pass] \
    [--srate hz] [--workdir dir] [--noaudio]
```

The UI is a fixed application shell: connection/session/mix in the left
sidebar, local channels and remote users as mixer cards in the center column,
chat on the right. The column and row splitters are draggable, meters show
peak-hold with dB ticks, and Enter in any connection field connects.

* **Local channels** pick up input channels and broadcast at the end of each
  interval (check *broadcast* to transmit).
* **Remote users** can be subscribed, mixed (volume/pan), muted and soloed.
* Chat supports `/msg <user> <text>` and `/topic <text>`.
* Received audio is decoded to your output; recordings can be kept as
  `.ogg` (+ `.wav`) under the work directory.

## Tree map

| path | what |
|---|---|
| `WDL/` | the WDL support library (SHA-1, RNG, buffers, `jnetlib` sockets, …) |
| `ninjam/` | client core (`NJClient`), protocol messages (`mpb`), framing (`netmsg`) |
| `ninjam/server/` | the NINJAM server (`ninjamsrv`) |
| `ninjam/imguiclient/` | **new** GUI client (Dear ImGui + GLFW, miniaudio audio) |
| `ninjam/tests/` | unit tests for the protocol layer + the end-to-end session test |
| `jmde/fx/reaninjam/` | the ReaNINJAM REAPER plug-in (needs the VST2 SDK; not in the CMake build) |
| `clients/` | historical client source drops (archives; not built) |
| `ninjam/{winclient,guiclient,cocoaclient,cursesclient,cmdclient--old,ninjamcast,autosong,cliplogcvt,ks,njasiodrv}/` | legacy client ports and tools (kept for reference; not built) |

## Notes on the 2026 revival

The maintained core and server were already in decent shape; the work here was
to make the whole system buildable and testable as one project, plus:

* Fixed pan values (documented −128..127) being parsed as unsigned in `mpb`.
* `NJClient::SetWorkDir` is now const-correct like the rest of the API.
* The GUI client was rebuilt around a proper application layout (draggable
  splitters, mixer cards, HiDPI-sized type, dB meters with peak hold, colored
  chat) replacing the old floating-window prototype.
* CMake build with automatic Ogg/Vorbis (client), GLFW/ImGui/miniaudio
  (GUI client); CTest unit tests (message roundtrips, SHA-1 vectors, framing)
  plus an end-to-end test that boots `ninjamsrv` on a free port and drives two
  headless clients  through connect, auth, user lists, chat and a full audio
  interval round-trip; GitHub Actions CI on macOS/Linux/Windows.
* Visual regression for the GUI: `ninjam_ui_snapshot` renders the UI offscreen
  (Dear ImGui with a software rasterizer - no window or GPU needed) and
  compares PNG snapshots against the golden images in `ninjam/tests/golden/`
  (scenarios: `empty`, `mixer`, `chat`; registered in CTest). After an
  intentional UI change, re-baseline with
  `./build/bin/ninjam_ui_snapshot --update`.

## License

GPL v2 or later for the NINJAM code (see `LICENSE` and file headers); WDL is
dual-licensed zlib/libpng-style or GPL (see file headers). Dear ImGui, GLFW
and miniaudio are fetched at build time and carry their own licenses
(MIT/Zlib/Public Domain).
