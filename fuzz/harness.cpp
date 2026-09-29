/*
    NINJAM protocol fuzzer harness.

    Feeds a fuzzer-provided client->server byte stream into the real, unmodified
    server connection code (Net_Message framing + User_Connection state machine +
    User_Group routing) through an in-memory implementation of JNL_IConnection.

    The stream is delivered in stages so the auth handshake completes the same
    way it does on the wire (the server only completes auth on a Run() pass
    that has no complete message pending, which is what the network round-trip
    of a real handshake provides):

      stage 1: the first framed message (expected to be MESSAGE_CLIENT_AUTH_USER)
      stage 2: everything after it, delivered in chunked arrivals
      stage 3: connection close, to exercise the disconnect/teardown paths

    The fake connection models TCP: arrived bytes accumulate in a receive
    watermark, with at most `chunk` new bytes arriving per run() tick, so
    messages split across arrivals are reassembled exactly like the real
    transport does.

    Build with ASan+UBSan and WDL's DEBUG_TIGHT_ALLOC so that any read or write
    even one byte past a message buffer lands in a sanitizer redzone.

    Note: this harness accepts every login (like a server configured with
    anonymous access) and grants full privileges, to maximize the amount of
    post-auth code the fuzzer can reach. Message parsing before auth is of
    course fuzzed as well.
*/

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../WDL/jnetlib/jnetlib.h"
#include "../WDL/wdlstring.h"
#include "../WDL/assocarray.h"

#include "../ninjam/server/usercon.h"

// ---------------------------------------------------------------------------
// stubs for symbols that live in ninjamsrv.cpp (which we do not link)
// ---------------------------------------------------------------------------

void logText(const char *s, ...)
{
  // keep fuzz runs quiet; NINJAM_FUZZ_LOG=1 mirrors log output to stderr
  static const int verbose = getenv("NINJAM_FUZZ_LOG") ? 1 : 0;
  if (!verbose) return;
  va_list ap;
  va_start(ap, s);
  vfprintf(stderr, s, ap);
  va_end(ap);
}

int g_config_private_maxsz; // 0 = private group mode disabled, stats paths no-op
static User_Group *m_group;
WDL_StringKeyedArray<User_Group *> g_private_groups(false);
WDL_FastString g_config_private_publicprefix;

// stub for the ninjamsrv.cpp implementation: with private group mode disabled
// (g_config_private_maxsz == 0) the real one returns "" immediately too
const char *get_privatemode_stats(int privs, const char *req)
{
  (void)privs; (void)req;
  return "";
}

// ---------------------------------------------------------------------------
// in-memory connection: serves a fixed client->server byte stream
// ---------------------------------------------------------------------------

class FuzzConnection : public JNL_IConnection
{
  public:
    FuzzConnection(const unsigned char *data, size_t size,
                   size_t *consumed_out, int *force_closed_out, int *alive_out)
      : m_data(data), m_size(size), m_pos(0), m_delivered(0),
        m_cap(0), m_chunk(0), m_sent_total(0),
        m_consumed_out(consumed_out), m_force_closed(force_closed_out),
        m_alive_out(alive_out)
    {
      *m_consumed_out = 0;
      *m_alive_out = 1;
    }

    virtual ~FuzzConnection() { *m_alive_out = 0; }

    // begin a new delivery stage: `cap` is the absolute stream position up to
    // which bytes will eventually arrive; `chunk` is the max new bytes per
    // run() tick (0 = everything at once)
    void set_stage(size_t cap, size_t chunk) { m_cap = cap; m_chunk = chunk; }

    void connect(const char *, int) { }
    void connect(SOCKET, struct sockaddr_in *) { }
    void run(int, int, int *bytes_sent=NULL, int *bytes_rcvd=NULL)
    {
      if (m_delivered < m_cap)
      {
        size_t t = m_cap;
        if (m_chunk && m_delivered + m_chunk < t) t = m_delivered + m_chunk;
        m_delivered = t;
      }
      if (bytes_sent) *bytes_sent=0;
      if (bytes_rcvd) *bytes_rcvd=0;
    }
    int get_state()
    {
      if (*m_force_closed) return JNL_Connection::STATE_CLOSED;
      if (m_sent_total > (32<<20)) return JNL_Connection::STATE_ERROR; // peer died
      return JNL_Connection::STATE_CONNECTED;
    }
    const char *get_errstr() { return "fuzzer"; }
    void close(int quick=0) { *m_force_closed = 1; }
    void flush_send(void) { }

    int send_bytes_in_queue(void) { return 0; }
    int send_bytes_available(void) { return 1<<20; }
    int send(const void *data, int length)
    {
      m_sent_total += length;
      return length;
    }
    int send_bytes(const void *data, int length) { return send(data,length); }
    int send_string(const char *line) { return send(line,(int)strlen(line)); }

    int recv_bytes_available(void)
    {
      return (int)(m_delivered - m_pos);
    }
    int recv_bytes(void *data, int maxlength)
    {
      int n = recv_bytes_available();
      if (n > maxlength) n = maxlength;
      if (n <= 0) return 0;
      memcpy(data, m_data + m_pos, n);
      m_pos += n;
      *m_consumed_out = m_pos;
      return n;
    }
    int recv_lines_available(void) { return 0; }
    int recv_line(char *line, int maxlength) { return 1; }
    int recv_get_linelen() { return 0; }
    int peek_bytes(void *data, int maxlength)
    {
      int n = recv_bytes_available();
      if (n > maxlength) n = maxlength;
      if (n <= 0) return 0;
      memcpy(data, m_data + m_pos, n);
      return n;
    }

    unsigned int get_interface(void) { return 0x0100007f; } // 127.0.0.1
    unsigned int get_remote(void) { return 0x0100007f; }
    short get_remote_port(void) { return 0; }
    void set_interface(int) { }
    SOCKET get_socket() const { return INVALID_SOCKET; }

    bool done() const { return m_pos >= m_size; }

  private:
    const unsigned char *m_data;
    size_t m_size;
    size_t m_pos;       // bytes consumed by the server
    size_t m_delivered; // bytes "arrived" over the fake transport
    size_t m_cap;       // stage limit for m_delivered
    size_t m_chunk;     // max arrival per run() tick
    size_t m_sent_total;
    size_t *m_consumed_out;
    int *m_force_closed;
    int *m_alive_out;
};

// ---------------------------------------------------------------------------
// user lookup: accept everybody, full privileges (see file header)
// ---------------------------------------------------------------------------

static const int FUZZ_MAX_CHANNELS = 32;

class FuzzUserInfoLookup : public IUserInfoLookup
{
  public:
    FuzzUserInfoLookup(const char *name) { username.Set(name); }
    int Run()
    {
      user_valid = 1;
      reqpass = 0;
      privs = PRIV_TOPIC|PRIV_CHATSEND|PRIV_BPM|PRIV_KICK|PRIV_ALLOWMULTI|
              PRIV_VOTE|PRIV_SHOW_PRIVATE;
      max_channels = FUZZ_MAX_CHANNELS;
      return 1;
    }
};

static IUserInfoLookup *FuzzCreateUserLookup(const char *username)
{
  return new FuzzUserInfoLookup(username);
}

// ---------------------------------------------------------------------------
// archive dir for the interval-upload (hostile audio payload) pass
// ---------------------------------------------------------------------------

static char g_archive_dir[512];
static long g_archive_passes;

static void rmdir_contents(const char *path)
{
  char cmd[1024];
  snprintf(cmd, sizeof(cmd), "rm -rf '%s'/* 2>/dev/null", path);
  int rc = system(cmd);
  (void)rc;
}

static void init_archive_dir()
{
  const char *base = getenv("TMPDIR");
  if (!base || !*base) base = "/tmp";
  snprintf(g_archive_dir, sizeof(g_archive_dir), "%s/ninjam_fuzz_archive_%d",
           base, (int)getpid());
  // User_Group::SetLogDir() creates the tree on first use
}

// ---------------------------------------------------------------------------
// driver
// ---------------------------------------------------------------------------

// pump the group until the stream is consumed and the connection has settled,
// or the user is gone, or a sane iteration cap is hit
static void pump_group(User_Group *group, const size_t *consumed, size_t total,
                       int max_iters)
{
  int idle = 0;
  for (int iter = 0; iter < max_iters; iter++)
  {
    if (!group->m_users.GetSize()) return;
    group->Run();
    if (*consumed >= total)
    {
      if (++idle >= 4) return;
    }
    else idle = 0;
  }
}

static void run_pass(const unsigned char *data, size_t size, size_t chunk,
                     int lobby_mode, int use_archive)
{
  if (size < 1) return;

  User_Group *group = new User_Group;
  group->CreateUserLookup = FuzzCreateUserLookup;
  group->SetConfig(32, 120); // BPI, BPM
  group->m_max_users = 0;    // unlimited
  group->m_keepalive = 0;
  group->m_voting_threshold = 50; // voting enabled, so !vote paths get fuzzed
  group->m_voting_timeout = 120;
  group->m_topictext.Set("fuzz topic");
  if (lobby_mode) group->m_is_lobby_mode = LOBBY_ALLOW_CHAT;
  if (use_archive) group->SetLogDir(g_archive_dir);

  size_t consumed = 0;
  int force_closed = 0;
  int alive = 1; // cleared by the connection's destructor when the server
                 // disconnects and deletes it mid-run

  FuzzConnection *con = new FuzzConnection(data, size, &consumed,
                                           &force_closed, &alive);
  group->AddConnection(con);

  // stage 1: deliver the first framed message (normally the auth user message),
  // then let the message-less runs complete the handshake
  size_t stage1 = 0;
  if (size >= 5)
  {
    unsigned int msz = (unsigned int)data[1] | ((unsigned int)data[2]<<8) |
                       ((unsigned int)data[3]<<16) | ((unsigned int)data[4]<<24);
    if (data[0] == MESSAGE_CLIENT_AUTH_USER && msz <= NET_MESSAGE_MAX_SIZE &&
        5 + (size_t)msz <= size)
    {
      stage1 = 5 + msz;
    }
  }
  if (stage1 > 0)
  {
    con->set_stage(stage1, stage1);
    pump_group(group, &consumed, stage1, 64);

    // stage 2: the rest of the stream, in chunked arrivals to exercise
    // fragmented frames
    if (alive && !con->done() && group->m_users.GetSize())
    {
      con->set_stage(size, chunk);
      pump_group(group, &consumed, size, 8192);
    }
  }
  else
  {
    // no leading auth message: hand over the raw stream (the server will
    // reject/kill, which is itself protocol behavior worth fuzzing)
    con->set_stage(size, chunk);
    pump_group(group, &consumed, size, 8192);
  }

  // stage 3: close the connection so disconnect/teardown paths run
  if (group->m_users.GetSize())
  {
    force_closed = 1;
    for (int i = 0; i < 8 && group->m_users.GetSize(); i++) group->Run();
  }

  delete group;

  if (use_archive && ++g_archive_passes % 4096 == 0) rmdir_contents(g_archive_dir);
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  if (size < 1 || size > 1<<20) return 0;

  // pass 1: normal jam group, moderate fragmentation
  run_pass(data, size, 1 + (size % 11), 0, 0);
  // pass 2: lobby mode (chat routing / room migration paths), bulk delivery
  run_pass(data, size, 0, 1, 0);
  // pass 3: session archiving enabled (hostile interval payloads hit disk)
  run_pass(data, size, 0, 0, 1);

  return 0;
}

extern "C" int LLVMFuzzerInitialize(int *argc, char ***argv)
{
  init_archive_dir();
  return 0;
}
