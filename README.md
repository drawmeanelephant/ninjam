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
configure time. On Linux, GLFW needs OpenGL and window-system dev packages.
CI installs `libgl1-mesa-dev xorg-dev libwayland-dev libwayland-bin
wayland-protocols libxkbcommon-dev` (Debian/Ubuntu names), which builds both
of GLFW's Linux backends (X11 and Wayland); `libgl1-mesa-dev xorg-dev` alone
is enough for an X11-only build.

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

## Server sizing and deployment

The server relays compressed audio intervals; clients encode, decode and mix
audio. Server CPU, memory and network use therefore depend mainly on concurrent
users, active channels, channel bitrates and the number of recipients. `MaxUsers`
limits concurrent users, and `MaxChannels <registered> [anonymous]` limits the
channels each user may send (up to the built-in limit of 32). Start with limits
that match the session instead of allowing more channels than participants need.

As a rough community-reported starting point, one upstream report describes
1 vCPU and 1 GB of RAM as comfortable for about four clients. Treat that as an
anecdote, not a sizing guarantee: this repository's end-to-end test checks a
two-client session, not server load. Test with the expected number of users,
channels and bitrates before relying on a deployment estimate.

The server listens on TCP port 2049 by default. Set `Port` in the server
configuration or pass `-port <port>` to override it, then allow that TCP port
through the host firewall and any network firewall in front of the server.

For a headless Linux deployment, install the built `ninjamsrv` binary and its
configuration, create a dedicated service account, and create writable log or
archive directories as needed. For example, with the paths adjusted to your
installation:

```ini
# /etc/systemd/system/ninjamsrv.service
[Unit]
Description=NINJAM server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ninjam
Group=ninjam
WorkingDirectory=/var/lib/ninjam
ExecStart=/opt/ninjam/bin/ninjamsrv /etc/ninjam/server.cfg -logfile /var/log/ninjam/server.log
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/ninjam /var/log/ninjam

[Install]
WantedBy=multi-user.target
```

Ensure the service account can read the config and any referenced license or
MOTD files, and can write to the configured log and archive paths. Then run
`systemctl daemon-reload`, `systemctl enable --now ninjamsrv`, and inspect
`systemctl status ninjamsrv` or `journalctl -u ninjamsrv`.

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
* **Auto-reconnect** is optional, toggled in the Connection panel and saved to
  `ninjam-client.ini` in the directory where the client starts. It retries
  unexpected disconnects with exponential backoff; clicking Disconnect does
  not retry.

## Tree map

| path | what |
|---|---|
| `WDL/` | the WDL support library (SHA-1, RNG, buffers, `jnetlib` sockets, …) |
| `ninjam/` | client core (`NJClient`), protocol messages (`mpb`), framing (`netmsg`) |
| `ninjam/server/` | the NINJAM server (`ninjamsrv`) |
| `ninjam/imguiclient/` | **new** GUI client (Dear ImGui + GLFW, miniaudio audio) |
| `ninjam/tests/` | unit tests for the protocol layer + the end-to-end session test |
| `zclient/` | an independent NINJAM client in Zig (protocol conformance; own Zig build, not in CMake) |
| `docs/` | wire-protocol specification (`PROTOCOL.md`) and investigation handoffs |
| `tools/` | interval-lab drivers and analyzers behind `REPORT.md` |
| `results/` | committed interval-lab run data behind `REPORT.md` |
| `fuzz/` | wire-protocol fuzz harness and corpus |
| `jmde/fx/reaninjam/` | the ReaNINJAM REAPER plug-in (needs the VST2 SDK; not in the CMake build) |
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
