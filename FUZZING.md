# FUZZING.md — protocol-aware fuzzing for the NINJAM server

A libFuzzer-based, protocol-aware fuzzer for `ninjamsrv`, plus triage tooling,
checked-in crash repros, and regression tests for every crash found.

## One-command run

```sh
make -C fuzz run          # builds everything, then fuzzes for 30 min (FUZZ_TIME)
```

or with a custom duration / parallelism:

```sh
make -C fuzz run FUZZ_TIME=600 FUZZ_JOBS=8
```

The run is unattended: fork mode keeps fuzzing past crashes and files each one
under `fuzz/artifacts/crash-<sha1>`. The seed corpus (`fuzz/corpus/seeds/`) and
the protocol dictionary (`fuzz/ninjam.dict`) are checked in, so a fresh clone
needs nothing else.

## Finding leaks

ASan only reports memory-safety errors, and leaks are a separate bug class. The
usual tool for them, LeakSanitizer, is missing from Apple's ASan runtime
entirely, and even on Linux it only runs once at process exit, so it cannot tell
the fuzzer *which input* leaked — crash 5 below was found that way by accident,
as a CI failure, not by the fuzzer.

So there is a second build of the same harness with per-input allocation
accounting:

```sh
make -C fuzz run-leak                # same session, leak detection on
tail -f fuzz/artifacts/leaks/leaks.log
```

Each input is executed twice and flagged only if *both* runs leave the same
positive residue, which is what separates a real per-input leak from one-time
initialization. A confirmed leak is written to `fuzz/artifacts/leaks/leak-<sha1>`
and the run continues, so one session can surface several distinct leaks;
`leaks.log` records every finding, including the allocation sites still holding
memory (libFuzzer's fork mode swallows the forked jobs' stdout, which is why
the log file exists). Filing stops after `NINJAM_FUZZ_LEAK_MAX` repros (default
20) because a single leaking bug makes thousands of near-duplicate inputs leak
— the cap is counted across the forked jobs, not per process. Expect roughly
half the throughput of `run`: two executions per input.

This is not speculative tooling: it is how crash 6 was found, on a build where
the four parser fixes and the lobby leak fix were already in. A 60-second
session on crash 5's code filed 20 repros, and a session on the *fixed* build
immediately produced a different, smaller leak that no sanitizer had reported —
a pre-auth one, described below. With all six fixes in, a 4-minute session
(1.3M executions, 1031 edges) files nothing.

## What the harness does

`fuzz/harness.cpp` links the **real, unmodified server code**
(`netmsg.cpp` framing, `usercon.cpp` connection state machine, `mpb.cpp`
message parsing) against an in-memory `JNL_IConnection`. The fuzzer input is
the client→server TCP byte stream. The harness:

1. delivers the first framed message (normally `MESSAGE_CLIENT_AUTH_USER`)
   and lets the message-less passes complete the handshake exactly as the
   network round-trip does — post-auth message handling is only reachable
   with a well-formed handshake, so every input must "speak" it;
2. delivers the rest of the stream in chunked arrivals (TCP-like receive
   watermark) to exercise fragmented frames; bulk delivery is fuzzed too;
3. runs each input against three group configurations — a normal jam, a
   private-group lobby (chat routing / room migration), and one with session
   archiving enabled (hostile interval / OGG payloads hit the
   `fwrite`/path-building code);
4. closes the connection at the end to exercise disconnect/teardown paths.

The harness accepts every login (like `AnonymousUsers yes`) and grants full
privileges to maximize reachable code. Pre-auth parsing (the auth message
itself, framing, overlong/invalid headers) is fuzzed as well.

Mutations come from libFuzzer (coverage-guided, with the checked-in dict)
over the raw byte stream: message type IDs, declared lengths, field contents,
truncated/fragmented frames, overlong frames (the framing cap is 16 KiB), and
hostile audio payloads. Note the server treats interval audio as opaque bytes
(relay + optional disk archive); OGG structures are only decoded client-side.

### Build configuration

The fuzz build uses `-fsanitize=address,undefined` **plus WDL's
`DEBUG_TIGHT_ALLOC`** (a `heapbuf.h` debug mode that makes `WDL_HeapBuf`
allocate exactly the requested size instead of rounding up to ~4 KiB). Without
it, 1-byte overflows land inside the allocation slack and ASan cannot see
them. It changes allocation strategy only, not behavior.

Toolchain note (macOS): Apple toolchains ship no libFuzzer runtime and the
Homebrew llvm@21 ASan runtime deadlocks at init on this OS, so `fuzz/Makefile`
builds libFuzzer from pinned sources (`llvmorg-21.1.8`, sparse-cloned into
`build/fuzz/`) with the Apple ASan runtime. On Linux with a full clang this is
a no-op you can skip by pointing `FUZZ_RUNTIME` at your prebuilt
`libclang_rt.fuzzer_osx.a`-equivalent.

## Regression tests (crash repros)

Every unique crash is checked in under `fuzz/corpus/crash-*.bin` together with
a fix on this branch. `ctest` runs `ninjam_fuzz_regression`
(`ninjam/tests/CMakeLists.txt`), which

1. replays every checked-in repro through the same code path, built with
   ASan+UBSan+`DEBUG_TIGHT_ALLOC`, and
2. runs API-level parser checks (`fuzz/regression_checks.cpp`), and
3. accounts for the leak in crash 5 by counting live allocations (see below).

If a fix is reverted, its repro aborts with a sanitizer error and the test
fails. Verified by reverting each fix in turn, one at a time:

| reverted fix | detected by | result |
|---|---|---|
| 1 -- auth_user scan | `crash-01-auth-username-oob.bin` | `heap-buffer-overflow` at `mpb.cpp:500`, SIGABRT |
| 2 -- chat trailing parm | `crash-02-chat-unterminated-parm.bin` | `heap-buffer-overflow` in `WDL_String::Set` (the handler copying the parm), SIGABRT |
| 3 -- channel_info record | `crash-03-chaninfo-name-oob.bin` | `heap-buffer-overflow` at `mpb.cpp:729`, SIGABRT |
| 4 -- usermask record | `crash-04-usermask-name-oob.bin` | `heap-buffer-overflow` at `mpb.cpp:630`, SIGABRT |
| 5 -- lobby notify leak | `fuzz/corpus/crash-05` replay | leak check reports `+9 allocs` instead of `+0`, exit 1 |
| 6 -- pre-auth refuse leak | `fuzz/corpus/crash-06` replay | leak check reports `+3 allocs` instead of `+0`, exit 1 |

With all six fixes in place, the whole `ctest` suite (unit, e2e, fuzz
regression) is green and all six repros replay with rc=0.

**Crash 5 is a leak, and leaks need a detector.** LeakSanitizer is part of
ASan on Linux, and it is what first flagged this one: the Linux CI run of the
suite reported it at process exit, and nothing else in the whole binary:

```text
Direct leak of 40 byte(s) in 1 object(s) allocated from:
    #1 mpb_server_userinfo_change_notify::build_add_rec(int, int, short, int, int, char const*, char const*)
Indirect leak of 12 byte(s) in 1 object(s) allocated from:
    #1 mpb_server_userinfo_change_notify::build_add_rec(...)
SUMMARY: AddressSanitizer: 52 byte(s) leaked in 2 allocation(s).
```

Apple's ASan runtime has no LSan (`detect_leaks is not supported on this
platform`), so the check in `fuzz/regression_checks.cpp` also accounts for the
leak without it: it overrides global `operator new`/`delete` to count live
allocations and compares two workloads, one client stream carrying a single
channel change and one carrying nine. The nine-message stream costs 9 live
`Net_Message`s with the fix reverted and 0 with it in — the same verdict LSan
gives on Linux, on every platform:

```sh
ASAN_OPTIONS=detect_leaks=1 ./build/fuzz/ninjam_fuzz \
    fuzz/corpus/crash-05-lobby-chaninfo-leak.bin -runs=1
```

Re-check a repro by hand any time:

```sh
make -C fuzz replay                    # replays fuzz/corpus/crash-*
./build/fuzz/ninjam_fuzz <file> -runs=1
```

### Wire-level replay against the real server binary

`fuzz/wire_replay.py` performs the client side of the handshake against a real
`ninjamsrv` process, then sends a file's bytes verbatim (`--raw` sends the
stream before the handshake, for pre-auth crashes; `--split N` chunks writes
to exercise TCP fragmentation):

```sh
python3 fuzz/wire_replay.py build/fuzz/ninjamsrv_asan_tight fuzz/test_server.cfg \
    fuzz/corpus/crash-02-chat-unterminated-parm.bin
```

It reports `ALIVE (no crash)` / `DEAD rc=… (crash)`; server logs and sanitizer
reports land in `/tmp/ninjam_wire_srv.log`.

## Coverage

Coverage-guided (libFuzzer edge counters). Final post-fix verification
session (with all five fixes in): 10 min, 4-way fork, **7.8M executions,
0 crashes** at ~12.7k execs/s aggregate:

```text
#7770799: cov: 1014 ft: 3783 corp: 574 exec/s: 3139 oom/timeout/crash: 0/0/0 time: 614s
INFO: exiting: 0 time: 614s
```

- **1014 edges / 3783 features**, corpus of 574 units, no new artifacts filed;
- per `-print_coverage=1`: all client→server message parsers covered
  (`mpb_client_auth_user`, `mpb_client_set_usermask`,
  `mpb_client_set_channel_info`, `mpb_client_upload_interval_begin/write`,
  `mpb_chat_message`), the full `User_Connection::Run` state machine, and
  `User_Group::onChatMessage` (MSG/PRIVMSG/ADMIN/!vote/lobby commands).

Not reachable by design (needs `ninjamsrv.cpp` machinery that is not linked
into the harness): private-group room creation/`get_privatemode_stats` body,
config-file parsing, socket accept loop. The wire-level replay covers the
accept loop; config parsing is local-file parsing, out of protocol scope.

## Crash inventory

Found: 6 unique bugs (1617+ fuzzer artifacts dedupe to the first four; the two
leaks were found by the leak-hunting build described above).
All 6 are **fixed on this branch**, each with a checked-in repro and a
regression test. None remain open.

| # | repro | crash site (pre-fix) | root cause | severity | stock-heap server |
|---|-------|----------------------|------------|----------|-------------------|
| 1 | `crash-01-auth-username-oob.bin` | `mpb_client_auth_user::parse`, mpb.cpp:500 | username scan `while (*p && len>0)` reads the byte at `buf[size]` when the username field has no NUL; **pre-auth reachable** | LOW–MED (OOB read, 1 byte past an exact-size heap buffer) | no crash (read lands in HeapBuf slack) |
| 2 | `crash-02-chat-unterminated-parm.bin` | strlen/strcmp in `onChatMessage` handlers | `mpb_chat_message::parse` returned success with a trailing parm that was **not NUL-terminated inside the message** (e.g. `MSG\0kick`); handlers call `strlen`/`strcmp`/pointer-walk on it | **HIGH** (remote DoS: any connected client crashes the server) | **yes — crashes the stock-heap ASan build** (READ of size 5 past the allocation) |
| 3 | `crash-03-chaninfo-name-oob.bin` | `mpb_client_set_channel_info::parse_get_rec` | channel-name scan reads past the buffer when the name is unterminated; also allowed up to 2 bytes of overflow when reading volume/pan/flags at record end | LOW–MED (OOB read) | no crash |
| 4 | `crash-04-usermask-name-oob.bin` | `mpb_client_set_usermask::parse_get_rec` | username scan reads past the buffer when the username is unterminated | LOW–MED (OOB read) | no crash |
| 5 | `crash-05-lobby-chaninfo-leak.bin` | `User_Connection::Run`, usercon.cpp:649 (lobby branch) | `mpb_server_userinfo_change_notify::build_add_rec()` allocates the class's internal `Net_Message`, and the class never frees it -- `mpb.h` states the caller must call `build()`. The channel-info handler only built+sent the notify outside lobby mode, so in a lobby every `set_channel_info` from any logged-in client leaked one message (~88 bytes + buffer), unbounded and remotely driven | **MED** (remote memory exhaustion: loop the message, grow the server until it dies) | n/a (silent, no crash) |
| 6 | `crash-06-preauth-refused-auth-leak.bin` | `User_Connection::Run`, usercon.cpp:542 (refuse path) | the auth-refusal path called `m_netcon.Run()` to flush the refusal, but `Net_Connection::Run()` also returns the next *received* message and the caller discarded it. A client that sent any non-auth frame followed by a well-formed one therefore leaked one `Net_Message` per refused connection -- **pre-auth, no lobby, no privileges, no handshake**; same flaw in the auth-timeout and `OnRunAuth`-failure flushes (usercon.cpp:492,512) | **MED–HIGH** (remote, pre-auth, trivially scripted memory exhaustion) | n/a (silent, no crash) |

Evidence (pre-fix, wire-level replay of the checked-in repros, exit code -6 =
SIGABRT):

```text
crash-01 vs pre-fix ninjamsrv_asan_tight: DEAD  |  stock-heap build: ALIVE
crash-02 vs pre-fix ninjamsrv_asan_tight: DEAD  |  stock-heap build: DEAD  ← real remote crash
crash-03 vs pre-fix ninjamsrv_asan_tight: DEAD  |  stock-heap build: ALIVE
crash-04 vs pre-fix ninjamsrv_asan_tight: DEAD  |  stock-heap build: ALIVE
```

Crash 5 leaks rather than crashes, so it is measured instead — replaying the
checked-in repro through the harness, counting live `Net_Message`s afterward:

```text
crash-05 with the fix reverted:  +9 live allocations  (one per channel-info message)
crash-05 with the fix in place:  +0
crash-06 with the fix reverted:  +3 live allocations  (one per refused connection)
crash-06 with the fix in place:  +0
```

The leak mode also names where the surviving memory was allocated, which is how
crash 6 was pinned down:

```text
LEAK: 2 allocation(s) survive replaying this input twice -> leak-artifacts/leak-cf4ab8e8...
LEAK:   live allocation 0x604000000b50 (40 bytes) from Net_Connection::Run(int*)
```

Post-fix, all four parser repros replay cleanly on both server builds and in
the harness, and the leak repros account for 0 leaked messages (and the full
ctest suite — unit, e2e, fuzz regression — passes).

### The fixes

**Crashes 1–4, all in `ninjam/mpb.cpp`.** Bounds-first scan conditions
(`while (len>0 && *p)` instead of `while (*p && len>0)`) so no read happens past
the last message byte; the chat parser refuses messages whose trailing parm is
not NUL-terminated inside the message instead of handing handlers a string that
reads past the buffer; the channel-info/usermask record iterators validate the
record layout before reading fields. Valid messages parse to byte-identical
results — no protocol feature was disabled (the existing unit tests in
`ninjam/tests/test_core.cpp` cover valid-message parsing and pass unchanged).

**Crash 5, in `ninjam/server/usercon.cpp`.** Build the notify message once and
release it when there is nobody to broadcast to, which is what `mpb.h` requires
of every caller of `build_add_rec()`:

```c
Net_Message *bmsg=mfmt.build();
if (bmsg)
{
  if (!group->m_is_lobby_mode) group->Broadcast(bmsg,this);
  else delete bmsg;
}
```

`Broadcast()` consumes the message (it addRefs, sends, and releases), so the
non-lobby path is unchanged; the lobby path — which previously skipped
`build()` entirely — now releases what `build_add_rec()` allocated. Lobby
semantics are untouched: no notify is sent in lobby mode, exactly as before.

**Crash 6, in `ninjam/server/usercon.cpp`.** `Net_Connection::Run()` does two
things: it flushes the send queue, *and* it parses and returns the next inbound
message. Three call sites wanted only the flush and threw the message away.
Release it:

```c
Net_Message *r=m_netcon.Run();
if (r) delete r;
```

A returned message arrives with no references, so the caller owns it; `delete`
matches how the other call site in the same function already disposes of one.
All three sites are fixed: the auth-refusal path (the reachable one), the
120-second authorization timeout, and the `OnRunAuth` failure flush.

### Was crash 5 the only one of its kind?

The ownership sweep says no — which is why the leak mode exists. Checking every
`build_add_rec()` call site (each pairs with a `build()` that
`Send()`/`Broadcast()` consume, including the guarded disconnect notify in
`User_Group::Run` and the `need_bcast` list in `onChatMessage`, whose early
returns all precede its first add) turned up nothing else. But a *different*
way to lose a message — ignoring what `Net_Connection::Run()` hands back — was
sitting in the same file, in a path the ownership audit never looks at because
no `build()` is involved. The framing layer itself checks out: the declared
size is validated against `NET_MESSAGE_MAX_SIZE` before allocation and
`parseAddBytes` clamps to the remaining bytes.

Two conclusions worth keeping: audits only find the bug class you think to look
for, and a leak detector that runs per input is worth more than one that runs
at process exit.
