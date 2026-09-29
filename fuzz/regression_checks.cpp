/*
    Regression checks for the six bugs the fuzzer found, one per fix.

    Checks 1-4 assert the post-fix behavior of the message parsers on the
    malformed shapes that used to read out of bounds, at the API level; they run
    with or without sanitizers. The sanitizer-backed replay of the checked-in
    repro files (fuzz/corpus/crash-*.bin) is the layer that catches reversions
    the API alone cannot expose.

    Checks 5 and 6 cover the two memory leaks, which have no API surface: they
    drive the real connection state machine through the fuzz harness and
    account for what the run failed to release.

    Return convention: 0 = passed, nonzero = failed.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <new>
#include <vector>

#include "../ninjam/netmsg.h"
#include "../ninjam/mpb.h"

// the leak check below drives the real connection state machine through the
// fuzz harness, which is a separate entry point from the parser API
extern "C" int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size);

// ---------------------------------------------------------------------------
// live-allocation counter
//
// LeakSanitizer is not available on every platform this suite runs on (Apple's
// ASan runtime ships without it), so the lobby-mode leak regression is checked
// by counting live C++ allocations across a workload instead. Net_Message --
// the object the leak loses -- is allocated with plain new, and the harness
// tears down its group between runs, so live-count growth is a direct measure
// of what the run failed to release.
// ---------------------------------------------------------------------------
static long g_live_allocs = 0;

void *operator new(size_t n)
{
  void *p = malloc(n ? n : 1);
  if (!p) throw std::bad_alloc();
  g_live_allocs++;
  return p;
}
void *operator new[](size_t n) { return operator new(n); }
void operator delete(void *p) noexcept { if (p) { g_live_allocs--; free(p); } }
void operator delete[](void *p) noexcept { operator delete(p); }
void operator delete(void *p, size_t) noexcept { operator delete(p); }
void operator delete[](void *p, size_t) noexcept { operator delete(p); }

static int g_failures;

#define CHECK(cond, ...) \
  do { \
    if (cond) printf("ok   " __VA_ARGS__), printf("\n"); \
    else { printf("FAIL " __VA_ARGS__), printf("\n"); g_failures++; } \
  } while (0)

// 1-byte little-endian size helper
static Net_Message *make_msg(unsigned char type, const unsigned char *payload, int len)
{
  Net_Message *m = new Net_Message;
  m->set_type(type);
  m->set_size(len);
  if (len) memcpy(m->get_data(), payload, len);
  return m;
}

// ---------------------------------------------------------------------------
// Crash 1: mpb_client_auth_user::parse read one byte past the message buffer
// when the username field had no NUL terminator (mpb.cpp:500 pre-fix).
// ---------------------------------------------------------------------------
static int check_auth_user()
{
  // 21-byte minimum message: 20-byte passhash + 1 non-NUL byte, no terminator
  unsigned char payload[21];
  memset(payload, 0x01, sizeof(payload));
  Net_Message *m = make_msg(MESSAGE_CLIENT_AUTH_USER, payload, (int)sizeof(payload));

  mpb_client_auth_user a;
  int rv = a.parse(m);
  CHECK(rv != 0, "auth_user: unterminated username rejected (rv=%d)", rv);
  delete m;

  // valid message still parses: hash + "anon\0" + caps + version
  unsigned char good[33];
  memset(good, 0x02, 20);
  memcpy(good + 20, "anon", 4);
  good[24] = 0;
  memset(good + 25, 0, 8);
  m = make_msg(MESSAGE_CLIENT_AUTH_USER, good, (int)sizeof(good));

  mpb_client_auth_user b;
  rv = b.parse(m);
  CHECK(rv == 0, "auth_user: valid message still accepted (rv=%d)", rv);
  CHECK(b.username && !strcmp(b.username, "anon"),
        "auth_user: username decoded correctly");
  delete m;
  return 0;
}

// ---------------------------------------------------------------------------
// Crash 2: mpb_chat_message::parse returned success with a trailing parm that
// was not NUL-terminated inside the message; handlers strlen()/strcmp() parms
// and read past the buffer (e.g. "MSG\0kick" or "ADMIN\0kick").
// ---------------------------------------------------------------------------
static int check_chat_message()
{
  // "MSG\0kick" - parm 1 runs to the end of the message, unterminated
  const unsigned char bad[] = {'M','S','G',0,'k','i','c','k'};
  Net_Message *m = make_msg(MESSAGE_CHAT_MESSAGE, bad, (int)sizeof(bad));

  mpb_chat_message c;
  int rv = c.parse(m);
  CHECK(rv != 0, "chat: unterminated trailing parm rejected (rv=%d)", rv);
  delete m;

  // "ADMIN\0kick" - the kick handler walks parms[1]+4 past the end pre-fix
  const unsigned char bad2[] = {'A','D','M','I','N',0,'k','i','c','k'};
  m = make_msg(MESSAGE_CHAT_MESSAGE, bad2, (int)sizeof(bad2));

  mpb_chat_message d;
  rv = d.parse(m);
  CHECK(rv != 0, "chat: ADMIN kick unterminated rejected (rv=%d)", rv);
  delete m;

  // "MSG\0text\0" - valid two-parm message, last parm ends the message
  const unsigned char good[] = {'M','S','G',0,'t','e','x','t',0};
  m = make_msg(MESSAGE_CHAT_MESSAGE, good, (int)sizeof(good));

  mpb_chat_message e;
  rv = e.parse(m);
  CHECK(rv == 0, "chat: valid message accepted (rv=%d)", rv);
  CHECK(e.parms[0] && !strcmp(e.parms[0], "MSG") &&
        e.parms[1] && !strcmp(e.parms[1], "text") && !e.parms[2],
        "chat: parms decoded correctly");
  delete m;

  // "PRIVMSG\0user\0" - valid message; empty trailing parm must not be a
  // dangling pointer to the end of the buffer
  const unsigned char pm[] = {'P','R','I','V','M','S','G',0,'u','s','e','r',0};
  m = make_msg(MESSAGE_CHAT_MESSAGE, pm, (int)sizeof(pm));

  mpb_chat_message f;
  rv = f.parse(m);
  CHECK(rv == 0, "chat: PRIVMSG with empty text accepted (rv=%d)", rv);
  CHECK(f.parms[2] == NULL, "chat: missing trailing parm is NULL, not end-pointer");
  delete m;
  return 0;
}

// ---------------------------------------------------------------------------
// Crash 3: mpb_client_set_channel_info::parse_get_rec scanned the channel
// name past the end of the message when unterminated, and could read up to
// 2 bytes past the buffer for the volume/pan/flags fields, and re-read the
// 2-byte header past the end on the record after the last one.
// ---------------------------------------------------------------------------
static int check_channel_info()
{
  // header says mpisize=4, then an unterminated channel name fills the rest
  const unsigned char rec[] = {0x04, 0x00, 'A','A','A','A'};
  Net_Message *m = make_msg(MESSAGE_CLIENT_SET_CHANNEL_INFO, rec, (int)sizeof(rec));

  mpb_client_set_channel_info chi;
  CHECK(chi.parse(m) == 0, "chaninfo: parse accepts message");

  const char *name = NULL;
  short vol = 0;
  int pan = 0, flags = 0;
  int offs = chi.parse_get_rec(0, &name, &vol, &pan, &flags);
  CHECK(offs <= 0, "chaninfo: unterminated name record stops cleanly (rv=%d)", offs);
  delete m;

  // valid single record must still parse: mpisize=4, name, 4 field bytes
  const unsigned char good[] = {0x04, 0x00, 'g','t','r',0, 0x10, 0x00, 0x40, 0x00};
  m = make_msg(MESSAGE_CLIENT_SET_CHANNEL_INFO, good, (int)sizeof(good));

  mpb_client_set_channel_info chi2;
  chi2.parse(m);
  name = NULL;
  offs = chi2.parse_get_rec(0, &name, &vol, &pan, &flags);
  CHECK(offs > 0, "chaninfo: valid record parses (rv=%d)", offs);
  CHECK(name && !strcmp(name, "gtr") && vol == 0x10 && pan == 0x40,
        "chaninfo: record fields decoded correctly");
  int offs2 = chi2.parse_get_rec(offs, &name, &vol, &pan, &flags);
  CHECK(offs2 <= 0, "chaninfo: clean stop after last record (rv=%d)", offs2);
  delete m;
  return 0;
}

// ---------------------------------------------------------------------------
// Crash 4: mpb_client_set_usermask::parse_get_rec scanned the username past
// the end of the message when unterminated.
// ---------------------------------------------------------------------------
static int check_usermask()
{
  // single record, username fills the message with no terminator
  const unsigned char rec[] = {'A','B','C','D','E'};
  Net_Message *m = make_msg(MESSAGE_CLIENT_SET_USERMASK, rec, (int)sizeof(rec));

  mpb_client_set_usermask um;
  CHECK(um.parse(m) == 0, "usermask: parse accepts message");

  const char *un = NULL;
  unsigned int fl = 0;
  int offs = um.parse_get_rec(0, &un, &fl);
  CHECK(offs <= 0, "usermask: unterminated username stops cleanly (rv=%d)", offs);
  delete m;

  // valid record: "bob\0" + 4-byte mask, then end of message
  const unsigned char good[] = {'b','o','b',0, 0x01,0x02,0x03,0x04};
  m = make_msg(MESSAGE_CLIENT_SET_USERMASK, good, (int)sizeof(good));

  mpb_client_set_usermask um2;
  um2.parse(m);
  offs = um2.parse_get_rec(0, &un, &fl);
  CHECK(offs > 0, "usermask: valid record parses (rv=%d)", offs);
  CHECK(un && !strcmp(un, "bob") && fl == 0x04030201,
        "usermask: record decoded correctly");
  int offs2 = um2.parse_get_rec(offs, &un, &fl);
  CHECK(offs2 <= 0, "usermask: clean stop after last record (rv=%d)", offs2);
  delete m;
  return 0;
}

// ---------------------------------------------------------------------------
// Crash 5 (memory leak, lobby mode): MESSAGE_CLIENT_SET_CHANNEL_INFO in a
// lobby-mode group called mpb_server_userinfo_change_notify::build_add_rec(),
// which allocates the class's internal Net_Message, and then skipped both
// build() and Broadcast() -- the group is in lobby mode, so there is nobody to
// notify. mpb.h states the contract plainly ("if you call build_add_rec at
// all, you must do delete x->build()"), and the class destructor does not free
// it, so every channel-info message a lobby client sent leaked one message
// (~88 bytes plus its heap buffer). Unbounded and remotely driven: re-send
// set_channel_info in a loop and the server grows until it dies.
//
// A leak needs a leak detector to be an assertion, so: feed the harness N
// channel-changing messages in a row (it runs every input against a normal
// group, a lobby group, and an archiving group) and compare the live
// allocation growth of a 1-message workload against a 9-message one. With the
// fix the two are the same; with it reverted, the 9-message workload leaks 8
// extra Net_Messages and this check fails.
// ---------------------------------------------------------------------------
static void append_le32(std::vector<unsigned char> &s, unsigned int v)
{
  s.push_back((unsigned char)(v & 0xff));
  s.push_back((unsigned char)((v >> 8) & 0xff));
  s.push_back((unsigned char)((v >> 16) & 0xff));
  s.push_back((unsigned char)((v >> 24) & 0xff));
}

static void append_frame(std::vector<unsigned char> &s, unsigned char type,
                         const unsigned char *payload, int len)
{
  s.push_back(type);
  append_le32(s, (unsigned int)len);
  s.insert(s.end(), payload, payload + len);
}

// auth_user + N set_channel_info messages, each naming channel 0 differently
// so every one of them registers as a change (and therefore builds a notify)
static std::vector<unsigned char> chaninfo_stream(int nchanges)
{
  std::vector<unsigned char> s;

  unsigned char auth[33];
  memset(auth, 0, sizeof(auth));     // the username's NUL lives at auth[24]
  memset(auth, 0x01, 20);            // passhash
  memcpy(auth + 20, "anon", 4);      // username + NUL
  auth[25] = 0x03;                   // caps
  auth[31] = 0x02;                   // client version 0x00020000
  append_frame(s, MESSAGE_CLIENT_AUTH_USER, auth, (int)sizeof(auth));

  for (int i = 0; i < nchanges; i++)
  {
    char nm[16];
    snprintf(nm, sizeof(nm), "c%d", i);

    unsigned char rec[32];
    int n = 0;
    rec[n++] = 4; rec[n++] = 0;                          // mpisize
    for (const char *p = nm; *p; p++) rec[n++] = (unsigned char)*p;
    rec[n++] = 0;                                         // name terminator
    rec[n++] = 0; rec[n++] = 0;                          // volume
    rec[n++] = 128;                                       // pan
    rec[n++] = 0;                                         // flags
    append_frame(s, MESSAGE_CLIENT_SET_CHANNEL_INFO, rec, n);
  }
  return s;
}

static long live_growth_for(int nchanges)
{
  std::vector<unsigned char> stream = chaninfo_stream(nchanges);
  long before = g_live_allocs;
  LLVMFuzzerTestOneInput(&stream[0], stream.size());
  return g_live_allocs - before;
}

static int check_lobby_chaninfo_leak()
{
  live_growth_for(1); // warm up one-time allocations so they are not counted

  long one = live_growth_for(1);
  long nine = live_growth_for(9);

  // 8 extra channel-info messages must not cost 8 extra live allocations
  CHECK(nine - one <= 2,
        "lobby chaninfo: no per-message leak (1 msg: +%ld allocs, 9 msgs: +%ld allocs)",
        one, nine);
  return 0;
}

// ---------------------------------------------------------------------------
// Crash 6 (memory leak, pre-auth): the refuse path called m_netcon.Run() to
// flush the refusal, but Run() also hands back the next message it manages to
// read off the wire, and the return value was discarded -- so a client that
// sent a bad frame followed by a good one leaked a Net_Message per refused
// connection, without authenticating at all. Unlike crash 5 this needs no
// lobby, no channel state and no privileges: eight empty frames are enough.
// ---------------------------------------------------------------------------
static std::vector<unsigned char> refused_auth_stream(int npairs)
{
  std::vector<unsigned char> s;
  for (int i = 0; i < npairs; i++)
    append_frame(s, 0x00, (const unsigned char *)"", 0); // empty, and not an auth frame
  return s;
}

static long live_growth_for_stream(const std::vector<unsigned char> &stream)
{
  long before = g_live_allocs;
  LLVMFuzzerTestOneInput(&stream[0], stream.size());
  return g_live_allocs - before;
}

static int check_refused_auth_leak()
{
  std::vector<unsigned char> stream = refused_auth_stream(8);
  live_growth_for_stream(stream); // warm up one-time allocations

  long residue = live_growth_for_stream(stream);
  CHECK(residue == 0,
        "pre-auth refuse: no leaked message after 8 refused connections "
        "(+%ld live allocs)", residue);
  return 0;
}

int run_regression_checks()
{
  check_auth_user();
  check_chat_message();
  check_channel_info();
  check_usermask();
  check_lobby_chaninfo_leak();
  check_refused_auth_leak();
  return g_failures ? 1 : 0;
}
