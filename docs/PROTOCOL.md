# NINJAM Wire Protocol Specification

Reverse-engineered from the reference implementation in this repository
(`ninjam/` client library, `ninjam/server/` server). This document describes
everything an implementer needs to build an interoperable client or server
without reading the C++ source. Every claim cites `file:line` against the
`main` tree.

Source of truth:

| Area | Files |
|------|-------|
| Message framing | `ninjam/netmsg.h`, `ninjam/netmsg.cpp` |
| Message payloads (parse/build) | `ninjam/mpb.h`, `ninjam/mpb.cpp` |
| Message type IDs | `ninjam/mpb.h:40-287` |
| Client state machine | `ninjam/njclient.cpp`, `ninjam/njclient.h` |
| Server connection handling | `ninjam/server/usercon.cpp`, `ninjam/server/usercon.h` |
| Server main loop / config | `ninjam/server/ninjamsrv.cpp` |
| Example server config | `ninjam/server/example.cfg` |

Exhaustiveness of the message-type list is proven in
[Appendix A](#appendix-a-exhaustiveness-of-the-message-set): every
`Send()`/receive site in the tree is enumerated, and no unlisted message type
exists.

---

## 1. Transport

* **Transport is plain TCP.** The client opens a `JNL_Connection` (JNetLib TCP)
  with 64 KiB send and receive buffers (`ninjam/njclient.cpp:899-902`); the
  server listens with `JNL_Listen` on the configured port and accepts with
  2×64 KiB / 64 KiB buffers (`ninjam/server/ninjamsrv.cpp:964`,
  `ninjam/server/ninjamsrv.cpp:983`).
* **Default port is 2049** (TCP): client default `NJ_PORT`
  (`ninjam/njclient.cpp:468`), server config default
  (`ninjam/server/ninjamsrv.cpp:582`), example config `Port 2049`
  (`ninjam/server/example.cfg:3`). A client may override the port with
  `host:port` syntax (`ninjam/njclient.cpp:890-898`).
* **TCP_NODELAY is set** on every NINJAM connection
  (`ninjam/netmsg.h:104-116`) — messages are latency-sensitive.
* There is no TLS and no proxy negotiation. The first bytes on the wire flow
  **server → client**: the server pushes an auth challenge the moment the
  connection is accepted (`ninjam/server/usercon.cpp:114-143`, called from
  `User_Group::AddConnection` at `ninjam/server/usercon.cpp:1093-1098`, which
  the accept loop calls at `ninjam/server/ninjamsrv.cpp:998`).
* The protocol is byte-stream framed by NINJAM itself (section 2); TCP
  segmentation is irrelevant to parsing.

## 2. Message framing

Every message on the wire is:

```
+--------+---------------------+------------------------------+
| type   | size (4 × 8 bits)   | payload (exactly `size` bytes)|
| 1 byte | uint32 little-endian| (may be empty)               |
+--------+---------------------+------------------------------+
    1 byte        4 bytes              `size` bytes
```

* Header is **5 bytes**: a 1-byte type followed by the payload size as a
  **uint32 little-endian**. Encoding:
  `ninjam/netmsg.cpp:53-73` (parse) and `ninjam/netmsg.cpp:75-88` (build).
* **All multi-byte integers anywhere in the protocol are little-endian.**
  (`ninjam/netmsg.cpp:60-63` for the header size; every payload field is
  serialized LSB-first, e.g. `ninjam/mpb.cpp:50-53`, `ninjam/mpb.cpp:511-519`.)
* Payload size limits:
  * `size` must satisfy `0 <= size <= 16384` (`NET_MESSAGE_MAX_SIZE`,
    `ninjam/netmsg.h:38`). A header with `size > 16384` is a framing error:
    the receiver aborts the connection (`ninjam/netmsg.cpp:65`,
    `ninjam/netmsg.cpp:183-186`).
  * Type `0xFF` is `MESSAGE_INVALID` and is likewise rejected at the framing
    layer (`ninjam/netmsg.h:44`, `ninjam/netmsg.cpp:65`).
  * Consequently the largest possible audio chunk in an interval-write
    message is `16384 - 17 = 16367` bytes (§ 5.8/§ 5.11).
* Messages are **self-delimiting**: a receiver reads 5 bytes, then exactly
  `size` bytes, then the next header. The reference receiver loops over
  available bytes, peeks, parses the header once, then consumes the payload
  (`ninjam/netmsg.cpp:174-202`). Partial headers/payloads are buffered until
  complete; the receive state machine never interleaves messages.
* There is no compression, no checksum, and no per-message acknowledgment.

### 2.1 Reserved type values

| Value | Name | Meaning |
|-------|------|---------|
| `0xFD` | `MESSAGE_KEEPALIVE` | Keepalive ping, sent automatically (`ninjam/netmsg.h:42`). See § 7. |
| `0xFE` | `MESSAGE_EXTENDED` | **Defined but never used anywhere in the tree** (`ninjam/netmsg.h:43`; sole reference). Treat as reserved: receivers ignore unknown types (§ 7.2), so do not rely on it. |
| `0xFF` | `MESSAGE_INVALID` | Illegal on the wire; framing error, disconnect (`ninjam/netmsg.h:44`, `ninjam/netmsg.cpp:65`). |

### 2.2 String encoding

Strings are NUL-terminated byte strings, transmitted **including** the
terminating NUL. No character-set conversion is performed anywhere; text is
effectively UTF-8 pass-through. The server maps all received control
characters (`< 0x20`) in relayed chat/topic text to spaces before rebroadcast
(`ninjam/server/usercon.cpp:81-89`, applied at
`ninjam/server/usercon.cpp:1316`, `ninjam/server/usercon.cpp:1348`,
`ninjam/server/usercon.cpp:1415`). Usernames are further restricted: the
server rewrites any character that is not alphanumeric, `-`, `_`, `@`, or `.`
to `_`, and truncates at 128 bytes (`MAX_NICK_LEN`,
`ninjam/server/usercon.cpp:110`, `ninjam/server/usercon.cpp:334-346`).

## 3. Protocol version and capability negotiation

* Protocol version range: `PROTO_VER_MIN = 0x00020000`,
  `PROTO_VER_MAX = 0x0002ffff`, `PROTO_VER_CUR = 0x00020000`
  (`ninjam/mpb.h:35-37`).
* The server advertises `PROTO_VER_CUR` in the auth challenge
  (`ninjam/server/usercon.cpp:125`). The client requires
  `PROTO_VER_MIN <= version < PROTO_VER_MAX` and otherwise disconnects with
  error "server is incorrect protocol version"
  (`ninjam/njclient.cpp:1037-1043`).
* The client sends its version in the auth user message; the server requires
  `PROTO_VER_MIN <= client_version <= PROTO_VER_MAX` and otherwise rejects
  with "incorrect client version" (`ninjam/server/usercon.cpp:527`,
  `ninjam/server/usercon.cpp:532`). Note the reference client always sends
  `PROTO_VER_CUR` (`ninjam/njclient.cpp:1047`).
* Capability words:
  * **`server_caps`** (challenge): bit 0 = a license agreement string is
    appended to the challenge message (`ninjam/mpb.cpp:60-73`,
    `ninjam/mpb.cpp:98-100`); **bits 8–15 = keepalive interval in seconds**
    (`ninjam/njclient.cpp:1049` reads `(caps>>8)&0xff`; the server sets
    `caps = keepalive<<8`, clamped to 0..255, at
    `ninjam/server/usercon.cpp:126-130`). All other bits are unused.
  * **`client_caps`** (auth user): bit 0 = user agreed to the license
    (`ninjam/mpb.h:175`; client sets it at `ninjam/njclient.cpp:1058`; server
    checks it at `ninjam/server/usercon.cpp:528`). Bit 1 historically
    indicated "client_version field present" (`ninjam/mpb.h:176-177`), but in
    this codebase the version field is **always** present on the wire
    (`ninjam/mpb.cpp:532`, `ninjam/mpb.cpp:555-558`) and always parsed by the
    server (`ninjam/mpb.cpp:509-519`). The reference client sends
    `client_caps` of 0 or 1 only (`ninjam/njclient.cpp:1045-1059`); servers
    must not require bit 1, and clients may set it or not without effect.

## 4. Handshake and authentication

### 4.1 Sequence

```
server                          client
  |                               |
  |-- 0x00 AUTH_CHALLENGE ------->|     (immediately on accept)
  |                               |  (optionally: user accepts license)
  |<-- 0x80 AUTH_USER ------------|
  |                               |
  |-- 0x01 AUTH_REPLY ----------->|     (success or failure)
  |-- 0x02 CONFIG_CHANGE_NOTIFY ->|     (BPM/BPI)
  |-- 0x03 USERINFO_CHANGE_NOTIFY-|     (current users, may be empty)
  |-- 0xC0 CHAT "TOPIC" --------->|
  |   (0xC0 CHAT "PRIVMSG" "*" -> |      MOTD lines, if configured)
  |                               |
  |<-- 0x82 SET_CHANNEL_INFO -----|     (client announces its channels)
  |                               |
  |-- 0xC0 CHAT "JOIN" ---------->|-> * (broadcast to *other* users)
```

The server constructs and sends the challenge in the `User_Connection`
constructor (`ninjam/server/usercon.cpp:114-143`), so it is the first data
after the TCP handshake.

### 4.2 Challenge (server → client)

See § 5.1 for the byte layout. The 8-byte challenge is random, generated with
`WDL_RNG_bytes` (`ninjam/server/usercon.cpp:119`).

### 4.3 Password hashing (client)

The client never sends the password. It computes (`ninjam/njclient.cpp:1063-1072`):

```
inner  = SHA1( username_utf8 || ':' || password_utf8 )
reply  = SHA1( inner || challenge )        -- challenge = the 8 challenge bytes
```

and places `reply` (20 bytes) in the auth user message. The server stores
`SHA1(username + ":" + password)` per account
(`ninjam/server/ninjamsrv.cpp:260-265`) and performs the identical second
hash over `SHA1(user:pass) || challenge`, comparing against the 20 bytes the
client sent (`ninjam/server/usercon.cpp:285-302`). A mismatch (or unknown
user, when a password is required) is answered with `flag=0` "invalid
login/password" and disconnect (`ninjam/server/usercon.cpp:294-302`).

### 4.4 Anonymous authentication

A username beginning with `anonymous` (`anonymous` exactly, or
`anonymous:desiredname`) is treated as anonymous **if the server allows it**
(`ninjam/server/ninjamsrv.cpp:186-213`):

* `reqpass` is cleared, so the password hash is **not verified** — the client
  must still send a well-formed 20-byte hash field, but its contents are
  ignored (`ninjam/server/usercon.cpp:295`).
* The effective username becomes `desiredname@<client-ip>` (or `anon@<ip>`
  when no name was requested). The desired name is truncated to 16
  characters and `@`/`.` are rewritten to `_`
  (`ninjam/server/ninjamsrv.cpp:194-215`).
* If the server has `AnonymousMaskIP yes`, the last octet of the IP in the
  name is replaced with `x` (`ninjam/server/ninjamsrv.cpp:218-228`).
* Anonymous users get the privileges configured by `AnonymousUsersCanChat`
  (chat permission), `AnonymousUsers multi` (multiple logins), and always
  `PRIV_VOTE`; channel count comes from `MaxChannels`'s anonymous value
  (`ninjam/server/ninjamsrv.cpp:230-231`).

### 4.5 License agreement

If the server has a license configured (`ServerLicense`), the license text is
appended to the challenge message and `server_caps` bit 0 is set
(`ninjam/server/usercon.cpp:132-136`, `ninjam/mpb.cpp:98-100`). The client
presents the text to the user (callback `ninjam/njclient.h:182-183`); if the
user accepts, `client_caps` bit 0 is set in the auth user message
(`ninjam/njclient.cpp:1053-1060`). A client that does not set the bit is
rejected with "license not agreed to" (`ninjam/server/usercon.cpp:528`,
`ninjam/server/usercon.cpp:532`).

While the license is pending, the connection's keepalive interval is relaxed
to 45 s on both sides so the user has time to read
(`ninjam/njclient.cpp:1053-1055`, `ninjam/server/usercon.cpp:134`).

### 4.6 Auth user timeout

The client must send `0x80` within **120 seconds** of connecting; afterwards
the server replies `flag=0` "authorization timeout" and disconnects
(`ninjam/server/usercon.cpp:501-514`). Caution for implementers: once the
challenge has been answered, this window closes; but note also that *any*
message that is not `0x80` received before authentication — including a
keepalive, if the client idles longer than its keepalive interval — is
treated as an invalid reply ("invalid authorization reply") and the
connection is killed (`ninjam/server/usercon.cpp:526`,
`ninjam/server/usercon.cpp:532`, `ninjam/server/usercon.cpp:541`). Send the
auth user message promptly after receiving the challenge.

### 4.7 Auth reply (server → client)

Failure: `flag = 0`, followed by a NUL-terminated human-readable error
string. Known strings produced by the reference server
(`ninjam/server/usercon.cpp:299`, `:398`, `:510`, `:532`):

* `invalid login/password`
* `server full` (account slots; `MaxUsers` minus hidden/reserved users,
  `ninjam/server/usercon.cpp:382-401`)
* `authorization timeout`
* `invalid authorization reply` / `incorrect client version` /
  `license not agreed to`

The client displays the string and disconnects
(`ninjam/njclient.cpp:1100-1108`).

Success: `flag = 1`, followed by a NUL-terminated string which is the
**effective username** assigned by the server (it may differ from what the
client sent: IP suffix, `-2` suffixes for multi-logins, sanitization —
`ninjam/server/usercon.cpp:348-379`), followed by one byte `maxchan`: the
number of channels this user may use (clamped to 32 = `MAX_USER_CHANNELS`
`ninjam/server/usercon.h:42`; **0 in lobby mode**,
`ninjam/server/usercon.cpp:183-195`). The client stores the effective
username and `maxchan` (`ninjam/njclient.cpp:1094-1098`).

### 4.8 Immediate post-auth server messages

After a successful auth the server sends, in order
(`ninjam/server/usercon.cpp:407-436`):

1. `0x01` auth reply (§ 4.7);
2. `0x02` config change notify with current BPM/BPI
   (`ninjam/server/usercon.cpp:411`, `:172-181`);
3. `0x03` user info change notify listing every other active user's channels
   (skipped in lobby mode; § 5.4, `ninjam/server/usercon.cpp:442-472`);
4. `0xC0` chat `PRIVMSG` from `"*"` per line of the MOTD file, if configured
   (`ninjam/server/usercon.cpp:416`, `:258-278`);
5. `0xC0` chat `TOPIC` with the current topic
   (`ninjam/server/usercon.cpp:418-424`);
6. (lobby only) `0xC0` chat `PRIVMSG` from `"*"` with lobby stats
   (`ninjam/server/usercon.cpp:426-429`, `:235-256`);
7. broadcast `0xC0` chat `JOIN <username>` to all *other* users
   (`ninjam/server/usercon.cpp:431-436`).

The client, upon success, immediately sends `0x82` set channel info
announcing its local channels (`ninjam/njclient.cpp:1085-1093`,
`ninjam/njclient.cpp:2884-2913`), which the server relays to everyone else as
`0x03` records (`ninjam/server/usercon.cpp:575-654`).

## 5. Message reference

Summary table (payload sizes exclude the 5-byte frame header):

| ID | Name | Direction | Min size | Notes |
|----|------|-----------|----------|-------|
| `0x00` | server_auth_challenge | S→C | 16 | + optional license text |
| `0x01` | server_auth_reply | S→C | 1 | + username/error, + maxchan |
| `0x02` | server_config_change_notify | S→C | 4 | exactly 4 |
| `0x03` | server_userinfo_change_notify | S→C | 0 | stream of records |
| `0x04` | server_download_interval_begin | S→C | 26 | + username |
| `0x05` | server_download_interval_write | S→C | 17 | + audio bytes |
| `0x80` | client_auth_user | C→S | 29 | 29 + len(username) |
| `0x81` | client_set_usermask | C→S | 0 | stream of records |
| `0x82` | client_set_channel_info | C→S | 2 | header + records |
| `0x83` | client_upload_interval_begin | C→S | 25 | exactly 25 |
| `0x84` | client_upload_interval_write | C→S | 17 | + audio bytes |
| `0xC0` | chat_message | both | 1 | up to 5 NUL strings |
| `0xFD` | keepalive | both | 0 | exactly 0 |

Minimum sizes are the values the parsers enforce (`ninjam/mpb.cpp:43`,
`:129`, `:188`, `:228`, `:363`, `:437`, `:490`, `:568`, `:758`, `:815`, `:865`
— noting `0x82`/`0x81`/`0x03` accept 0 and decode records lazily). `0xFD`
keepalive frames are 5 bytes total (empty payload).

### 5.1 `0x00` server_auth_challenge

`ninjam/mpb.cpp:40-121`. Fields in order:

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 8 | bytes | `challenge` — random nonce |
| 8 | 4 | uint32 LE | `server_caps` (§ 3) |
| 12 | 4 | uint32 LE | `protocol_version` |
| 16 | *n* | NUL string | license agreement text; **present iff `server_caps & 1`** |

### 5.2 `0x01` server_auth_reply

`ninjam/mpb.cpp:126-181`.

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 1 | byte | `flag` — bit 0 set = success |
| 1 | *n* | NUL string | success: effective username; failure: error text. Omitted when the message is just 1 byte. |
| 1+n | 1 | byte | `maxchan` — max local channels (success only; present iff there is a byte after the string) |

### 5.3 `0x02` server_config_change_notify

`ninjam/mpb.cpp:185-221`. Exactly 4 bytes:

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 2 | uint16 LE | `beats_minute` — BPM |
| 2 | 2 | uint16 LE | `beats_interval` — BPI (beats per interval) |

Sent on join, on any BPM/BPI change (admin command, vote result, room
creation), and on config reload (`ninjam/server/usercon.cpp:411`,
`:1083-1091`, `:1242-1245`, `:1275-1278`, `:1522-1525`;
`ninjam/server/ninjamsrv.cpp:1023`). The client recomputes its interval
length and starts audio on receipt
(`ninjam/njclient.cpp:1112-1121`, `ninjam/njclient.cpp:725-732`,
`ninjam/njclient.cpp:786-819`).

### 5.4 `0x03` server_userinfo_change_notify

`ninjam/mpb.cpp:225-356` (record builder `:251-299`, record parser
`:303-356`). A stream of concatenated records; empty payload = empty user
list. Record layout:

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 1 | byte | `active` — 1 = channel exists, 0 = channel removed |
| 1 | 1 | byte | `channelid` — 0..31 (clamped to 0..255 at build; clients must validate < 32) |
| 2 | 2 | int16 LE | `volume` — dB × 10 (e.g. 10 = +1 dB) |
| 4 | 1 | int8 | `pan` — −128..127 |
| 5 | 1 | byte | `flags` — see § 6.3 |
| 6 | *n* | NUL string | `username` |
| 6+n | *m* | NUL string | `channel name` |

Semantics (`ninjam/njclient.cpp:1123-1258`): each record with `active=1`
creates or updates `(username, channelid)`; `active=0` removes it, and when a
user's last channel is removed the user disappears
(`ninjam/njclient.cpp:1237-1242`). The server sends the full list on join
(`ninjam/server/usercon.cpp:442-472`), deltas on channel-info changes
(`ninjam/server/usercon.cpp:609-652`), removals on user disconnect
(`ninjam/server/usercon.cpp:1041-1064`), and additions on lobby→room
migration (`ninjam/server/ninjamsrv.cpp:1071-1090`). If a user has no active
channels, the server synthesizes one placeholder record (channel 0, empty
name) so UIs show the user (`ninjam/server/usercon.cpp:465-468`) unless
hidden users are allowed.

### 5.5 `0x04` server_download_interval_begin

`ninjam/mpb.cpp:360-430`. Announces the start of one user's audio transfer
for one interval:

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 16 | bytes | `guid` — transfer ID |
| 16 | 4 | uint32 LE | `estsize` — estimated total bytes (informational; reference client always sends 0, `ninjam/njclient.cpp:1495`, `ninjam/njclient.cpp:1542`) |
| 20 | 4 | uint32 LE | `fourcc` — codec tag, `"OGGv"` (§ 6.2); 0 = special (§ 6.1) |
| 24 | 1 | byte | `chidx` — uploader's channel index |
| 25 | *n* | NUL string | `username` — uploader's effective name (added by the server, `ninjam/server/usercon.cpp:704-713`) |

### 5.6 `0x05` server_download_interval_write

`ninjam/mpb.cpp:434-474`. One chunk of the transfer announced by § 5.5:

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 16 | bytes | `guid` — matches the begin |
| 16 | 1 | byte | `flags` — bit 0 set on the **final** chunk |
| 17 | *n* | bytes | raw Ogg Vorbis stream data (§ 6.2) |

Byte-identical layout to `0x84` — the server forwards client uploads by
rewriting only the type byte (`ninjam/server/usercon.cpp:798-799`).

### 5.7 `0x80` client_auth_user

`ninjam/mpb.cpp:487-561`.

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 20 | bytes | `passhash` = SHA1(SHA1(user:pass) ‖ challenge) (§ 4.3); ignored for anonymous |
| 20 | *n* | NUL string | `username` (may be `anonymous:name`) |
| 20+n | 4 | uint32 LE | `client_caps` (§ 3) |
| 24+n | 4 | uint32 LE | `client_version` |

### 5.8 `0x81` client_set_usermask

`ninjam/mpb.cpp:565-646`. Subscription state: one record per remote user the
client wants to hear. Record:

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | *n* | NUL string | `username` |
| n | 4 | uint32 LE | `channelmask` — bit *k* set = subscribe to channel *k* of that user |

Empty payload is valid. Sending a mask of 0 for an existing entry unsubscribes
(`ninjam/server/usercon.cpp:656-697`). The server routes interval data only
to subscribed users (§ 6.4). The reference client sends this when
auto-subscribing new users (`ninjam/njclient.cpp:1184-1190`) and when the
local user toggles a subscription (`ninjam/njclient.cpp:2602-2640`).

### 5.9 `0x82` client_set_channel_info

`ninjam/mpb.cpp:650-751`. Announces the sender's own local channels. Layout:

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 2 | uint16 LE | `mpisize` — per-record info size; **4** in this protocol (`ninjam/mpb.h:206`, `ninjam/mpb.cpp:685-690`) |
| 2 | … | records | concatenation of per-channel records |

Each record (`ninjam/mpb.cpp:676-712`):

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | *n* | NUL string | `channel name` |
| n | 2 | int16 LE | `volume` — dB × 10 (client sends 0; `ninjam/njclient.cpp:2907`) |
| n+2 | 1 | int8 | `pan` — −128..127 (client sends 0) |
| n+3 | 1 | byte | `flags` — bit 0x80 = **inactive/filler channel** (§ 6.3) |

The *i*-th record describes channel *i*. The server assigns `active = !(flags
& 0x80)` (`ninjam/server/usercon.cpp:594`), ignores records beyond the user's
`maxchan` (`ninjam/server/usercon.cpp:590`), treats all channels beyond the
last record as removed (`ninjam/server/usercon.cpp:622-639`), and broadcasts
the delta as `0x03` records to everyone else
(`ninjam/server/usercon.cpp:652`). The client re-sends this message after any
local channel change (`ninjam/njclient.h:166`,
`ninjam/njclient.cpp:2759`, `ninjam/njclient.cpp:2884-2913`).

### 5.10 `0x83` client_upload_interval_begin

`ninjam/mpb.cpp:755-808`. Exactly 25 bytes — same first 25 bytes as § 5.5
but **without** the username (the server knows the sender):

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 16 | bytes | `guid` |
| 16 | 4 | uint32 LE | `estsize` |
| 20 | 4 | uint32 LE | `fourcc` |
| 24 | 1 | byte | `chidx` |

### 5.11 `0x84` client_upload_interval_write

`ninjam/mpb.cpp:812-852`. Byte-identical layout to § 5.6.

### 5.12 `0xC0` chat_message

`ninjam/mpb.cpp:862-920`. Payload is up to **5** NUL-terminated strings
concatenated (`parms[0..4]`, `ninjam/mpb.h:276`). The reference builder
always emits all five slots, so trailing unused parameters appear as bare
NUL bytes (`ninjam/mpb.cpp:891-917`); a parser must accept messages with
fewer parameters present (`ninjam/mpb.cpp:873-880` stops at the end of the
payload). Commands are case-sensitive (`ninjam/njclient.h:195`). See § 8 for
the full command set.

## 6. Audio transfer model (intervals)

### 6.1 Musical timing and the interval

* The server owns the tempo: BPM (beats/minute) and BPI (beats/interval),
  delivered via `0x02` (`ninjam/server/usercon.cpp:172-181`). Defaults are
  120 BPM / 8 BPI unless configured (`ninjam/server/ninjamsrv.cpp:589-590`,
  `ninjam/server/example.cfg:39-40`); limits in the shipped config paths are
  `MIN_BPM 40, MAX_BPM 400, MIN_BPI 2, MAX_BPI 128` (`ninjam/server/usercon.h:57-60`,
  clamps at `ninjam/server/ninjamsrv.cpp:334-346`). (The `/bpm` chat admin
  command separately accepts 20–400 BPM and 2–1024 BPI —
  `ninjam/server/usercon.cpp:1501-1515` — an inconsistency in the reference
  server; treat 40–400 / 2–128 as the safe range.)
* Interval duration: `seconds = BPI × 60 / BPM`. The client computes the
  interval in samples as `bpi / (bpm/60) × samplerate`
  (`ninjam/njclient.cpp:794-806`); the server computes the same interval in
  wall-clock ms as `60 000 × bpi / bpm`
  (`ninjam/server/usercon.cpp:992`, `:1000`).
* All users' intervals are aligned to the *server's* clock: the server merely
  logs interval ticks (`ninjam/server/usercon.cpp:1012-1017`); clients align
  by starting their intervals when they receive/apply `0x02` and keeping time
  locally (`ninjam/njclient.cpp:786-819`). An interoperable client must
  upload each interval's audio *during* that interval (see § 6.5) and play
  downloads one interval later (that is the NINJAM latency-hiding trick; the
  client buffers decoded audio per channel, `ninjam/njclient.cpp:2508-2534`).

### 6.2 Audio encoding: Ogg Vorbis inside interval messages

* The only codec in this protocol is Ogg Vorbis, tagged by fourcc
  `MAKE_NJ_FOURCC('O','G','G','v')` = `0x7647474F`
  (`ninjam/njclient.cpp:37`, `ninjam/njclient.cpp:89`), which serialized
  little-endian appears on the wire as the four ASCII bytes `O G G v`
  (`4F 47 47 76`).
* The payload bytes of interval-write messages (§ 5.6/§ 5.11) are **raw,
  consecutive slices of a standard Ogg Vorbis bitstream**. The reference
  client encodes with libvorbis (VBR, quality derived from the channel
  bitrate, random stream serial number; `ninjam/njclient.cpp:1504`, encoder
  in `WDL/vorbisencdec.h:251-331`) and transmits the encoder output verbatim:
  the first chunks a receiver sees for a guid are the stream's Ogg pages
  (identification/comment/setup headers), followed by audio pages.
* A receiver reconstructs the stream by **concatenating the payload bytes of
  all interval-write chunks with the same guid, in arrival order**, into one
  buffer/file, and handing it to any Ogg Vorbis decoder
  (`ninjam/njclient.cpp:3166-3177` — `RemoteDownload::Write` appends to a
  file and/or an in-memory buffer that feeds the decoder). There is no extra
  per-chunk framing beyond the message header.
* Chunks are sized by the encoder's buffering: at least ~2 KiB per message in
  normal mode (hard cap `MAX_ENC_BLOCKSIZE = 9216`, `ninjam/njclient.cpp:460-461`,
  `:1572`), smaller granularity in live/voicechat mode
  (`ninjam/njclient.cpp:1567-1570`, `:463-465`). An interop implementation
  may chunk however it likes within the 16367-byte payload limit.
* **Special guids/fourccs** (`ninjam/server/usercon.cpp:716-751`,
  `ninjam/njclient.cpp:1271-1308`):
  * `guid = 0` (16 zero bytes) **and** `fourcc = 0`: a *silence marker*. The
    client sends `0x83` with zero guid/fourcc when a channel stops
    broadcasting (`ninjam/njclient.cpp:1484-1498`). The server relays the
    begin to subscribers but tracks no transfer
    (`ninjam/server/usercon.cpp:719`, `:768-778`). A client receiving it
    schedules one silent interval for that channel
    (`ninjam/njclient.cpp:1271-1284`).
  * `fourcc = 0` with nonzero guid: a reference to a previously transferred
    stream (session-mode replay); clients that have the guid cached re-use
    it (`ninjam/njclient.cpp:1298-1308`). The server still relays it.
  * `guid != 0, fourcc != 0`: a normal audio transfer.

### 6.3 Channel flags

Bit field used in `0x03`/`0x82` records (`ninjam/mpb.h:215`):

| Bit | Meaning |
|-----|---------|
| `&1` | no default subscribe |
| `&2` | "instamode" (live/voicechat: fixed tiny intervals, no interval boundary flush) |
| `&4` | session mode (arbitrary-length chunks + `SESSION` chat messages, § 8) |
| `&0x80` | filler: channel is inactive (`ninjam/server/usercon.cpp:594`, `ninjam/njclient.cpp:2909`) |

### 6.4 Transfer routing and subscriptions

The server relays uploads **only to subscribed users**
(`ninjam/server/usercon.cpp:754-784`): for each other user with a
`usermask` entry naming the uploader where `channelmask & (1<<chidx)`, the
server rewrites the `0x83` begin into a `0x04` begin with the uploader's
username appended and forwards it, registering a transfer state so subsequent
`0x84` writes are forwarded as `0x05` (`ninjam/server/usercon.cpp:790-859`).
Transfer state expires after 8 idle seconds (`TRANSFER_TIMEOUT`,
`ninjam/server/usercon.h:112`, `ninjam/server/usercon.cpp:821`, `:851`); the
client similarly drops downloads idle for 8 s (`DOWNLOAD_TIMEOUT`,
`ninjam/njclient.h:285`, `ninjam/njclient.cpp:1344-1349`).

### 6.5 Client upload lifecycle

For each broadcasting local channel, per interval
(`ninjam/njclient.cpp:1446-1701`):

1. On the first encoded data of the interval, generate a fresh 16-byte
   random guid (`ninjam/njclient.cpp:1511`) and build the `0x83` begin
   (fourcc `OGGv`, `chidx`, `estsize` 0) — but hold it
   (`ninjam/njclient.cpp:1538-1544`).
2. When the first chunk of encoded audio is available, send the held `0x83`,
   then `0x84` chunks with `flags = 0` as data becomes available
   (`ninjam/njclient.cpp:1567-1600`).
3. At the interval boundary, flush the encoder and send the remaining chunks;
   the last one has `flags & 1` set (`ninjam/njclient.cpp:1606-1645`).
   *An implementation must terminate every announced transfer with a
   flags&1 chunk* — otherwise transfer state lingers until the 8 s timeout.
4. When a channel goes silent (stops broadcasting), send one `0x83` with
   zero guid and fourcc 0 at the boundary (`ninjam/njclient.cpp:1484-1498`,
   transition detection `ninjam/njclient.cpp:2489-2504`).

The `0x82` channel-info message must be sent before/with the first uploads so
other users have the channel in their user list (client does it right after
auth success, `ninjam/njclient.cpp:1093`).

## 7. Keepalive and connection teardown

### 7.1 Keepalive

* If nothing has been sent for `keepalive` seconds, either side sends
  `0xFD` with an empty payload (`ninjam/netmsg.cpp:104-112`).
* The interval comes from the server: `server_caps` bits 8–15
  (`ninjam/server/usercon.cpp:126-130` → `ninjam/njclient.cpp:1049`, applied
  at `ninjam/njclient.cpp:1061`); value 0 falls back to
  `NET_CON_KEEPALIVE_RATE = 3` seconds (`ninjam/netmsg.h:46`,
  `ninjam/netmsg.h:124-128`). The server's value is configured by
  `SetKeepAlive` (`ninjam/server/ninjamsrv.cpp:359-364`,
  `ninjam/server/example.cfg:55-57`).
* Receiving **any** message (including `0xFD`) refreshes the peer's liveness
  timestamp (`ninjam/netmsg.cpp:211-214`).

### 7.2 Disconnect conditions

| Condition | Detected by | Cite |
|-----------|-------------|------|
| No inbound message for `3 × keepalive` seconds | both sides — connection error | `ninjam/netmsg.cpp:215-218` |
| Invalid frame header (type `0xFF`, size > 16384) | both sides | `ninjam/netmsg.cpp:65`, `:183-186` |
| Send queue overflow (> 512 queued messages) | both sides | `ninjam/netmsg.h:40`, `ninjam/netmsg.cpp:228-235` |
| TCP error/close | both sides | `ninjam/netmsg.cpp:293-297` |
| No auth within 120 s of connect | server | `ninjam/server/usercon.cpp:501-514` |
| Non-`0x80` message before auth (incl. keepalive) | server | `ninjam/server/usercon.cpp:526`, `:541-547` |
| Failed auth / version / license / full | server → sends `0x01` flag=0 first | § 4.7 |

* Unknown message types **after** auth are silently ignored by both sides
  (`ninjam/njclient.cpp:1437-1439`; `ninjam/server/usercon.cpp:873-874`).
  This includes `0xFD` keepalives on the application level — they are
  consumed by the connection layer's liveness logic.
* On user disconnect the server broadcasts `0xC0` `PART <username>` and
  `0x03` removal records for all the user's channels
  (`ninjam/server/usercon.cpp:1028-1065`).

## 8. Chat subsystem (`0xC0`)

Parameters are positional (`parms[0]` first string). Commands are
case-sensitive; usernames are matched case-insensitively
(`ninjam/server/usercon.cpp:670`, `:1357`).

### 8.1 Client → server commands

| Command |Parms| Behavior |
|---------|-------|----------|
| `MSG` | `<text>` | Broadcast text to everyone. Text may begin with `!` for special commands (below). Requires chat privilege. Server relays as `MSG <sender> <text>` (`ninjam/server/usercon.cpp:1111-1319`). |
| `PRIVMSG` | `<username>` `<text>` | Private message. Exact (case-insensitive) match first, then partial match if the prefix ends at an `@` or contains one (`ninjam/server/usercon.cpp:1337-1396`). Relay: `PRIVMSG <sender> <text>`. |
| `SESSION` | `<guid-hex>` `<chidx>` `<start> <len>` | Session-mode block descriptor; relayed with the sender's name inserted as parm 1 (`ninjam/server/usercon.cpp:1325-1336`). Sent by session-mode clients (`ninjam/njclient.cpp:1648-1670`). |

`!`-commands inside `MSG` text (`ninjam/server/usercon.cpp:1117-1304`):
`!topic` (query topic), `!vote bpm <n>` / `!vote bpi <n>` (voting system,
privilege-gated), and in lobby mode `!stat`, `!join <room>`; any other text
starting with `!` gets a command-list reply.

The reference server additionally documents `TOPIC <topic>` as a
client→server command (`ninjam/mpb.h:281`), but this server's dispatcher does
not handle it — topic changes go through the `ADMIN` command below; an
incoming `TOPIC` falls through to the unknown branch and is dropped
(`ninjam/server/usercon.cpp:1573-1575`).

### 8.2 `ADMIN` (client → server)

`ADMIN <command ...>` (`ninjam/server/usercon.cpp:1397-1572`). Commands:
`topic <text>` (priv `T`), `kick <user|prefix*>` (priv `K`), `bpm <n>` /
`bpi <n>` (priv `B`), `stat` (private-mode stats), `join <room>` (lobby
only). Errors are sent back as `MSG` from the empty username
(`ninjam/server/usercon.cpp:1577-1584`).

### 8.3 Server → client messages

| Command | Parms | Meaning |
|---------|-------|---------|
| `MSG` | `<username>` `<text>` | Public message from `<username>`; empty username = server/system message (`ninjam/njclient.h:192`) |
| `PRIVMSG` | `<username>` `<text>` | Private message; username `"*"` = server notice (MOTD, lobby stats, lobby help) (`ninjam/server/usercon.cpp:249-253`, `:269-273`, `:1147`, `:1159`) |
| `TOPIC` | `<changed-by>` `<topic>` | Topic; empty `<changed-by>` on join/`!topic` query (`ninjam/server/usercon.cpp:208-212`, `:1119-1124`, `:1416-1421`) |
| `JOIN` | `<username>` | A user joined (`ninjam/server/usercon.cpp:431-436`, `ninjam/server/ninjamsrv.cpp:1063-1069`) |
| `PART` | `<username>` | A user left (`ninjam/server/usercon.cpp:1035-1039`, `ninjam/server/ninjamsrv.cpp:1057-1061`) |
| `USERCOUNT` | `<count>` `<max>` | Sent once to a joining (status) client (`ninjam/server/usercon.cpp:214-232`) |
| `SESSION` | `<username>` `<guid-hex>` `<chidx>` `<start> <len>` | Session descriptor from another user (`ninjam/njclient.cpp:1361-1399`) |

## 9. Server configuration knobs that affect the wire

From `ninjam/server/ninjamsrv.cpp:285-565` and `ninjam/server/example.cfg`:

| Directive | Wire effect |
|-----------|-------------|
| `Port <n>` | TCP listen port (default 2049) (`ninjam/server/ninjamsrv.cpp:289-294`, `:582`) |
| `MaxUsers <n>` | Excess users rejected with `server full` (`ninjam/server/ninjamsrv.cpp:301-306`; `ninjam/server/usercon.cpp:382-401`) |
| `MaxChannels <user> [anon]` | Bounds the `maxchan` byte of auth replies and per-user upload/channel limits (`ninjam/server/ninjamsrv.cpp:352-358`; `ninjam/server/usercon.cpp:187-191`, `:590`, `:702`) |
| `ServerLicense <file>` | License text appended to `0x00`; `server_caps` bit 0; clients must echo agreement in `client_caps` bit 0 (`ninjam/server/ninjamsrv.cpp:375-398`; `ninjam/server/usercon.cpp:132-136`, `:528`) |
| `SetKeepAlive <s>` | Keepalive seconds, sent in `server_caps` bits 8–15 (`ninjam/server/ninjamsrv.cpp:359-364`; `ninjam/server/usercon.cpp:126-130`) |
| `DefaultBPM` / `DefaultBPI` | Initial values of `0x02` (`ninjam/server/ninjamsrv.cpp:333-346`, `:972-973`) |
| `DefaultTopic <text>` | Text of the `TOPIC` chat message on join (`ninjam/server/ninjamsrv.cpp:347-351`; `ninjam/server/usercon.cpp:418-424`) |
| `MOTDFile <file>` | Lines sent as `PRIVMSG` from `"*"` on join (`ninjam/server/ninjamsrv.cpp:317-321`; `ninjam/server/usercon.cpp:258-278`) |
| `User <name> <pass> [privs]` | Account table; priv letters `*TBCKRMHVP` map to topic/bpm/chat/kick/reserve/multi-login/hidden/vote/show-private privileges (`ninjam/server/ninjamsrv.cpp:437-469`; flags `ninjam/server/usercon.h:47-56`). Default privs: chat + vote (`ninjam/server/ninjamsrv.cpp:467`) |
| `AnonymousUsers no\|yes\|multi` | Enables anonymous auth; `multi` allows concurrent same-name logins (server appends `.N` to the name, `ninjam/server/usercon.cpp:361-368`) (`ninjam/server/ninjamsrv.cpp:481-492`) |
| `AnonymousUsersCanChat yes\|no` | Grants chat privilege to anonymous users (`ninjam/server/ninjamsrv.cpp:515-525`, `:230`) |
| `AnonymousMaskIP yes\|no` | Masks IP in anonymous effective names (`ninjam/server/ninjamsrv.cpp:493-503`, `:218-228`) |
| `AllowHiddenUsers yes\|no` | Whether channel-less users appear (synthesized `0x03` record suppressed) (`ninjam/server/ninjamsrv.cpp:470-480`; `ninjam/server/usercon.cpp:465-468`, `:640-650`) |
| `StatusUserPass <u> <p>` | Special status account: auths, receives user list + config/topic/usercount, then is disconnected — used by server-list pingers (`ninjam/server/ninjamsrv.cpp:237-251`, `:295-300`; `ninjam/server/usercon.cpp:305-329`) |
| `ACL <cidr> allow\|deny\|reserve` | Connection-level filtering/reserved slots; no message-level effect (`ninjam/server/ninjamsrv.cpp:399-436`, `:987-999`) |
| `SetVotingThreshold <n>` / `SetVotingVoteTimeout <s>` | Governs `!vote` acceptance and the `0x02` broadcast on a successful vote (`ninjam/server/ninjamsrv.cpp:365-374`; `ninjam/server/usercon.cpp:1165-1295`) |
| `PrivateGroupMode` / `PrivateGroupLobbySize` / `PrivateGroupAllowChat` / `PrivateGroupLobbyMOTDFile` / `PrivateGroupPublicPrefix` | Lobby mode: joining users get `maxchan = 0`, no user list, `!join <room>` migrates them to a new `User_Group` (fresh `0x01`/`0x02`/userlist/topic sequence) (`ninjam/server/ninjamsrv.cpp:526-561`, `:1004-1101`; `ninjam/server/usercon.cpp:189`, `:444`) |
| `SessionArchive <path> <minutes>` | Server-side recording of interval uploads to disk; no wire effect (`ninjam/server/ninjamsrv.cpp:322-327`; `ninjam/server/usercon.cpp:726-748`) |

## 10. Worked transcript

A complete, byte-annotated session against a server configured with
`DefaultBPM 120`, `DefaultBPI 8`, `MaxChannels 32 2`, `AnonymousUsers no`,
one registered user, and one existing user **bob** (channel 0 "guitar") who
has subscribed to everyone. Client user **alice** / password **secret**
connects from `203.0.113.7` and is accepted as `alice@203.0.113.7`. HMAC-free
auth values below are real SHA-1 outputs:

```
SHA1("alice:secret")                        = 6985e52cea44a28695d5c440bd42f57e9f50b7b1
challenge                                   = 0123456789abcdef
SHA1(6985…b7b1 || 0123456789abcdef)         = 63fd01e27c12cc2ad826ae47b4d6b2c9fd20a42e
```

Notation: each frame is `type size` header then payload; comments show field
breakdown. Sizes are decimal.

### 10.1 Connect and authenticate

```
S>C  00 10 00 00 00                       AUTH_CHALLENGE, size 16
       01 23 45 67 89 AB CD EF            challenge (8)
       00 03 00 00                        server_caps = 0x00000300
                                          (keepalive 3 s in bits 8-15, no license bit)
       00 00 02 00                        protocol_version = 0x00020000

C>S  80 22 00 00 00                       AUTH_USER, size 34
       63 FD 01 E2 7C 12 CC 2A D8 26      passhash (20) =
       AE 47 B4 D6 B2 C9 FD 20 A4 2E        SHA1(SHA1("alice:secret")||challenge)
       61 6C 69 63 65 00                  username "alice\0"
       00 00 00 00                        client_caps = 0 (no license was offered)
       00 00 02 00                        client_version = 0x00020000

S>C  01 14 00 00 00                       AUTH_REPLY, size 20
       01                                 flag = success
       61 6C 69 63 65 40 32 30 33 2E      effective username "alice@203.0.113.7\0"
       30 2E 31 31 33 2E 37 00
       20                                 maxchan = 32 (MaxChannels' registered-user value)
```

### 10.2 Post-auth configuration

```
S>C  02 04 00 00 00                       CONFIG_CHANGE_NOTIFY, size 4
       78 00                              BPM = 120
       08 00                              BPI = 8
                                          (interval = 8 × 60 / 120 = 4.0 s)

S>C  03 11 00 00 00                       USERINFO_CHANGE_NOTIFY, size 17
       01                                 active = 1
       00                                 channelid = 0
       00 00                              volume = 0 (0.0 dB)
       00                                 pan = 0
       00                                 flags = 0
       62 6F 62 00                        username "bob\0"
       67 75 69 74 61 72 00               channel name "guitar\0"

S>C  C0 30 00 00 00                       CHAT_MESSAGE, size 48
       "TOPIC\0"                         parms[0]
       "\0"                              parms[1] (empty: not changed by a user)
       "Welcome to NINJAM. Please play nicely.\0"   parms[2]
       00 00                             parms[3], parms[4] (empty; the builder
                                          always emits all five slots)
```

### 10.3 Alice announces her channel

```
C>S  82 12 00 00 00                       SET_CHANNEL_INFO, size 18
       04 00                              mpisize = 4
       63 68 61 6E 6E 65 6C 20 6F 6E 65 00   channel name "channel one\0"
       00 00                              volume = 0
       00                                 pan = 0
       00                                 flags = 0 (active)

S>C(bob)  03 24 00 00 00                  USERINFO_CHANGE_NOTIFY relayed to bob, size 36
       01 00                              active, channelid
       00 00 00 00                        volume
       00 00                              pan, flags
       61 6C 69 63 65 40 32 30 33 2E      "alice@203.0.113.7\0"
       30 2E 31 31 33 2E 37 00
       63 68 61 6E 6E 65 6C 20 6F 6E 65 00   "channel one\0"

S>C(bob)  C0 1A 00 00 00                  CHAT_MESSAGE to bob, size 26
       "JOIN\0" "alice@203.0.113.7\0"     parms[0], parms[1]
       00 00 00                           parms[2..4] empty
                                          (bob's client may reply with a
                                           SET_USERMASK subscribing to alice;
                                           payload e.g.
                                           "alice@203.0.113.7\0" 01 00 00 00)
```

### 10.4 One full interval exchange (4 seconds, BPI 8 @ 120 BPM)

Alice broadcasts on channel 0. Her client uploads during the interval; the
server relays to bob (subscribed). Chunks marked `…` elide Ogg page bytes.

```
C>S  83 19 00 00 00                       UPLOAD_INTERVAL_BEGIN, size 25
       00 × 16                            guid = 0
       00 00 00 00                        estsize = 0
       00 00 00 00                        fourcc = 0
       00                                 chidx = 0
     (silence marker emitted at the boundary where her channel last went
      quiet; if she has been broadcasting continuously this frame is absent)

C>S  83 19 00 00 00                       UPLOAD_INTERVAL_BEGIN, size 25
       A1 B2 C3 D4 E5 F6 07 18            guid = a1b2c3d4e5f60718
       29 3A 4B 5C 6D 7E 8F 90              293a4b5c6d7e8f90 (random, 16 bytes)
       00 00 00 00                        estsize = 0
       4F 47 47 76                        fourcc "OGGv"
       00                                 chidx = 0

S>C(bob)  04 2B 00 00 00                  DOWNLOAD_INTERVAL_BEGIN to bob, size 43
       A1 B2 … 8F 90                      same guid (16)
       00 00 00 00                        estsize
       4F 47 47 76                        fourcc "OGGv"
       00                                 chidx
       61 6C 69 63 65 40 32 30 33 2E      "alice@203.0.113.7\0"   <- server adds
       30 2E 31 31 33 2E 37 00

C>S  84 45 00 00 00                       UPLOAD_INTERVAL_WRITE, size 69
       A1 B2 … 8F 90                      guid (16)
       00                                 flags = 0
       4F 67 67 53 …                      52 bytes of Ogg Vorbis stream
                                          (starts with "OggS" page: id header)

S>C(bob)  05 45 00 00 00                  DOWNLOAD_INTERVAL_WRITE to bob, size 69
       (identical payload; only the type byte changed)

C>S  84 25 00 00 00                       UPLOAD_INTERVAL_WRITE, size 37
       A1 B2 … 8F 90                      guid
       01                                 flags = 1  <- final chunk of interval
       … 20 bytes of Ogg Vorbis data …

S>C(bob)  05 25 00 00 00                  DOWNLOAD_INTERVAL_WRITE to bob
       (final chunk likewise)

S>C(alice) 04 2B 00 00 00                 bob's interval arrives for alice the
           …                              same way, with username "bob\0"
S>C(alice) 05 … 00 00 00                  (alice subscribed via auto-subscribe)
```

### 10.5 Chat

```
C>S  C0 16 00 00 00                       CHAT_MESSAGE, size 22
       "MSG\0" "hello everyone\0"         parms[0], parms[1]
       00 00 00                           parms[2..4] empty

S>C(bob)  C0 27 00 00 00                  CHAT_MESSAGE relayed, size 39
       "MSG\0"
       "alice@203.0.113.7\0"              sender inserted by server
       "hello everyone\0"
       00 00                              parms[3..4] empty

S>C(alice) C0 30 00 00 00                 (if someone changes the topic)
           "TOPIC\0" "bob\0" "<new topic>\0" + trailing empty slots
```

### 10.6 Steady state

After the exchange above the connection simply continues: each interval both
clients upload their channels (§ 6.5) and receive the channels they
subscribe to; either side may emit `0xFD 00 00 00 00` (5 bytes, empty
payload) whenever it has nothing else to send for one keepalive period (3 s
here).

## Appendix A: Exhaustiveness of the message set

All message IDs are defined in one place, `ninjam/mpb.h:40-287` (plus the
framing-level types in `ninjam/netmsg.h:42-44`). Grepping the entire tree for
`MESSAGE_` usage outside the definitions yields exactly these files:
`ninjam/netmsg.cpp` (framing: invalid/keepalive), `ninjam/njclient.cpp`
(client dispatch), `ninjam/server/usercon.cpp` (server dispatch), and
`ninjam/tests/test_core.cpp` (round-trip tests of the mpb codecs). No other
translation unit constructs or inspects protocol messages.

### A.1 Client sends (`m_netcon->Send` / `ChatMessage_Send`)

| Site | Message |
|------|---------|
| `ninjam/njclient.cpp:1074` | `0x80` auth user |
| `ninjam/njclient.cpp:1189` | `0x81` usermask (auto-subscribe) |
| `ninjam/njclient.cpp:2619`, `:2639` | `0x81` usermask (subscribe toggle) |
| `ninjam/njclient.cpp:1496` | `0x83` begin — silence marker (zero guid/fourcc) |
| `ninjam/njclient.cpp:1590`, `:1638` | `0x83` begin — audio (built `:1538-1544`, held until first data) |
| `ninjam/njclient.cpp:1596`, `:1643` | `0x84` write |
| `ninjam/njclient.cpp:1669` → `:1773` | `0xC0` chat (`SESSION`) |
| `ninjam/njclient.cpp:1773` | `0xC0` chat (public API `ChatMessage_Send`, `njclient.h:189`) |
| `ninjam/netmsg.cpp:108-110` | `0xFD` keepalive (automatic) |

### A.2 Client receives (dispatch switch, `ninjam/njclient.cpp:1030-1440`)

| Case | Message |
|------|---------|
| `:1032` | `0x00` challenge |
| `:1080` | `0x01` auth reply |
| `:1112` | `:1112` | `0x02` config change |
| `:1123` | `0x03` userinfo change |
| `:1260` | `0x04` download begin |
| `:1314` | `0x05` download write |
| `:1355` | `0xC0` chat |
| `:1437-1439` | everything else (incl. `0xFD`): ignored |

### A.3 Server sends

| Site | Message |
|------|---------|
| `ninjam/server/usercon.cpp:138` | `0x00` challenge (on connect) |
| `ninjam/server/usercon.cpp:194` | `0x01` auth success (`SendAuthReply`; reused for room migration at `ninjam/server/ninjamsrv.cpp:1092`) |
| `ninjam/server/usercon.cpp:300`, `:398`, `:510`, `:541` | `0x01` auth failures |
| `ninjam/server/usercon.cpp:179`, `:203` | `0x02` config (`SendConfigChangeNotify` / `SendConnectInfo`) |
| `ninjam/server/usercon.cpp:1090` (`SetConfig`), `:1245`, `:1278` (votes), `:1525` (admin bpm/bpi) | `0x02` config broadcast |
| `ninjam/server/usercon.cpp:471` | `0x03` user list (`SendUserList`; also `ninjam/server/ninjamsrv.cpp:1093`) |
| `ninjam/server/usercon.cpp:652`, `:1064`; `ninjam/server/ninjamsrv.cpp:1089` | `0x03` delta broadcasts |
| `ninjam/server/usercon.cpp:778` | `0x04` download begin (relay) |
| `ninjam/server/usercon.cpp:842` | `0x05` download write (relay, retyped at `:798`) |
| `ninjam/server/usercon.cpp:208-212` (`SendConnectInfo`), `:418-424` (join), `:1119-1124` (`!topic`), `:1416-1421` (`ADMIN topic`) | `0xC0` `TOPIC` |
| `ninjam/server/usercon.cpp:214-232` | `0xC0` `USERCOUNT` |
| `ninjam/server/usercon.cpp:249-253`, `:269-273`, `:426-429`, `:1128-1163` | `0xC0` `PRIVMSG` from `"*"` (MOTD, lobby stats/help) |
| `ninjam/server/usercon.cpp:431-436`, `ninjam/server/ninjamsrv.cpp:1063-1069` | `0xC0` `JOIN` |
| `ninjam/server/usercon.cpp:1035-1039`, `ninjam/server/ninjamsrv.cpp:1057-1061` | `0xC0` `PART` |
| `ninjam/server/usercon.cpp:1306-1319` (`MSG` relay), `:1172`, `:1197`, `:1232-1258`, `:1301`, `:1394`, `:1462-1465`, `:1506`, `:1514`, `:1577-1584`; `ninjam/server/ninjamsrv.cpp:1046-1050` | `0xC0` `MSG` (broadcast/system) |
| `ninjam/server/usercon.cpp:1337-1396` | `0xC0` `PRIVMSG` relay |
| `ninjam/server/usercon.cpp:1325-1336` | `0xC0` `SESSION` relay |

### A.4 Server receives (`User_Connection::Run`, `ninjam/server/usercon.cpp:475-880`)

| Case | Message |
|------|---------|
| `:521-568` | `0x80` pre-auth (any other type pre-auth → reject, `:526`) |
| `:575` | `0x82` channel info |
| `:656` | `0x81` usermask |
| `:698` | `0x83` upload begin |
| `:790` | `0x84` upload write |
| `:863` | `0xC0` chat |
| `:873-874` | everything else (incl. `0xFD`): ignored |

No sender or receiver for any type outside this list exists in the tree, and
no type is defined that is not accounted for above (`0xFE` `MESSAGE_EXTENDED`
is defined at `ninjam/netmsg.h:43` and referenced nowhere else).

## Appendix B: Implementer's checklist

1. TCP connect; read `0x00`; validate `16 <= protocol_version` bounds
   (§ 3) and note keepalive from caps bits 8–15.
2. Compute the double SHA-1 (§ 4.3); send `0x80` **immediately** (§ 4.6).
3. Expect `0x01`; on failure display error string and close; on success store
   effective username and `maxchan`.
4. Expect `0x02` (starts your musical clock), `0x03` (user list), `0xC0`
   `TOPIC`; optional `PRIVMSG`-`"*"` MOTD lines.
5. Send `0x82` with your channels (respect `maxchan`).
6. Auto-subscribe (optional): send `0x81` records.
7. Per interval: upload per § 6.5; parse `0x04`/`0x05` pairs per § 6.4,
   concatenating payloads by guid and decoding as Ogg Vorbis (§ 6.2).
8. Send `0xFD` when idle `keepalive` seconds; treat `3 × keepalive` of
   silence as a dead connection (§ 7).
9. Ignore unknown message types and unknown chat commands; never send text
   containing bytes < 0x20.
