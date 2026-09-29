/*
    API-level regression checks for the NINJAM parser bounds fixes.

    Each check documents the malformed message shape that used to trigger an
    out-of-bounds read and asserts the parser's post-fix observable behavior.
    These run with or without sanitizers; the sanitizer-backed replay of the
    checked-in repro files (fuzz/corpus/crash-*.bin) is the second layer that
    catches reversions the API alone cannot expose.

    Return convention: 0 = passed, nonzero = failed.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../ninjam/netmsg.h"
#include "../ninjam/mpb.h"

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

int run_regression_checks()
{
  check_auth_user();
  check_chat_message();
  check_channel_info();
  check_usermask();
  return g_failures ? 1 : 0;
}
