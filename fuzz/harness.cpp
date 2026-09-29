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

#ifdef NINJAM_FUZZ_LEAK_CHECK
static long g_live_allocs = 0;
#endif

static int fuzz_body(const uint8_t *data, size_t size)
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

// ---------------------------------------------------------------------------
// leak detection (built with -DNINJAM_FUZZ_LEAK_CHECK; see the ninjam_fuzz_leakcheck
// target in the Makefile)
//
// ASan only catches memory-safety errors. Leaks are a separate bug class, and
// the usual tool for them -- LeakSanitizer -- is missing from Apple's ASan
// runtime entirely, and even where it exists it runs once at process exit, so it
// cannot tell the fuzzer which input leaked. It found crash 5 here only by
// accident, as a CI failure.
//
// This mode accounts for live allocations per input instead. run_pass() tears
// down its group before returning, so whatever a run fails to release is a net
// positive residue. Each input is executed twice and only flagged when *both*
// runs leave the same positive residue, which is what separates a real
// per-input leak from one-time initialization (that leaves residue on the first
// run only).
//
// A confirmed leak is written to $NINJAM_FUZZ_LEAK_DIR as leak-<sha1>, the
// same "one file per distinct finding" shape as libFuzzer's crash-<sha1>
// artifacts, and the run continues. Aborting instead would make every forked
// job die on the first known leak and the session would never get past its own
// seed corpus; filing and continuing keeps coverage feedback alive so one run
// can surface several distinct leaks. Filing stops at $NINJAM_FUZZ_LEAK_MAX
// (default 20) because a single leaking bug makes thousands of near-duplicate
// inputs leak.
// ---------------------------------------------------------------------------
#ifdef NINJAM_FUZZ_LEAK_CHECK

#include <new>
#include <dlfcn.h>
#include "../WDL/sha.h"

#ifdef _WIN32
#include <direct.h>
#define FUZZ_MKDIR(p) _mkdir(p)
#else
#include <dirent.h>
#include <sys/stat.h>
#define FUZZ_MKDIR(p) mkdir(p,0755)
#endif

// Which code allocated what. A ring of the most recent allocations, so a
// confirmed finding can name the call sites that are still holding memory --
// without one, "this input leaks 2 allocations" is a triage dead end.
// __builtin_return_address is a single instruction; capturing a real backtrace
// per allocation would cost far more than the run itself.
#define LEAK_SITE_RING 512
#define LEAK_SITE_IDX 2048
static void *g_site_ptr[LEAK_SITE_RING];
static void *g_site_ra[LEAK_SITE_RING];
static size_t g_site_size[LEAK_SITE_RING];
static int g_site_next = 0;
// direct-mapped pointer -> ring slot, so operator delete can clear the slot
// without scanning the ring; a stale slot would otherwise be reported as a
// leak site long after the memory was freed
static int g_site_index[LEAK_SITE_IDX];

static size_t g_last_alloc_size;

static void note_alloc(void *p, void *ra)
{
  int slot = g_site_next;
  g_site_ptr[slot] = p;
  g_site_ra[slot] = ra;
  g_site_size[slot] = g_last_alloc_size;
  g_site_index[((uintptr_t)p >> 4) % LEAK_SITE_IDX] = slot;
  g_site_next = (g_site_next + 1) % LEAK_SITE_RING;
}

static void note_free(void *p)
{
  int idx = (int)(((uintptr_t)p >> 4) % LEAK_SITE_IDX);
  int slot = g_site_index[idx];
  if (slot >= 0 && slot < LEAK_SITE_RING && g_site_ptr[slot] == p)
  {
    g_site_ptr[slot] = 0;
    g_site_ra[slot] = 0;
    g_site_size[slot] = 0;
  }
}

void *operator new(size_t n)
{
  void *p = malloc(n ? n : 1);
  if (!p) throw std::bad_alloc();
  g_live_allocs++;
  g_last_alloc_size = n;
  note_alloc(p, __builtin_return_address(0));
  return p;
}
void *operator new[](size_t n) { return operator new(n); }
void operator delete(void *p) noexcept { if (p) { g_live_allocs--; note_free(p); free(p); } }
void operator delete[](void *p) noexcept { operator delete(p); }
void operator delete(void *p, size_t) noexcept { operator delete(p); }
void operator delete[](void *p, size_t) noexcept { operator delete(p); }

// live allocations this input failed to release; also leaves the ring marked at
// the point the run started, so the finding can name allocation sites from this
// run rather than from the fuzzer's own bookkeeping
static long leak_residue(const uint8_t *data, size_t size, int *ring_mark)
{
  *ring_mark = g_site_next;
  long before = g_live_allocs;
  fuzz_body(data, size);
  return g_live_allocs - before;
}

static char g_leak_dir[1024];
static char g_leak_log[1200];
static int g_leak_dir_ready = 0;
static int g_leak_max = 20;
static int g_leak_capped = 0;

// how many leak-* inputs are already filed; used to keep the cap global across
// the forked jobs, each of which is a fresh process
static int count_filed_leaks()
{
#ifdef _WIN32
  return 0; // no cheap directory scan here; the per-process cap applies
#else
  DIR *d = opendir(g_leak_dir);
  if (!d) return 0;
  int n = 0;
  struct dirent *e;
  while ((e = readdir(d)))
  {
    if (!strncmp(e->d_name, "leak-", 5)) n++;
  }
  closedir(d);
  return n;
#endif
}

static void init_leak_dir()
{
  const char *d = getenv("NINJAM_FUZZ_LEAK_DIR");
  if (!d || !*d) d = "leak-artifacts";
  lstrcpyn_safe(g_leak_dir, d, sizeof(g_leak_dir));
  FUZZ_MKDIR(g_leak_dir);

  const char *m = getenv("NINJAM_FUZZ_LEAK_MAX");
  if (m && *m) g_leak_max = atoi(m);

  // libFuzzer's fork mode swallows everything the forked jobs print, so every
  // finding is also appended here; `tail -f` on this file is how an unattended
  // leak hunt is watched.
  snprintf(g_leak_log, sizeof(g_leak_log), "%s/leaks.log", g_leak_dir);
  g_leak_dir_ready = 1;
}

static void report_leak(const char *line)
{
  printf("%s", line);
  fflush(stdout);
  if (g_leak_dir_ready)
  {
    FILE *log = fopen(g_leak_log, "ab");
    if (log) { fprintf(log, "%s", line); fclose(log); }
  }
}

// file the offending input; the sha1 name dedups re-finds of the same input
static void file_leak(const uint8_t *data, size_t size, long residue, int ring_mark)
{
  if (!g_leak_dir_ready) init_leak_dir();

  // One leaking bug makes thousands of near-duplicate inputs leak, so the
  // number of filed repros is capped (libFuzzer caps leaks for the same
  // reason). The count is global across forked jobs, which are separate
  // processes, so a per-process counter would restart at zero on every job and
  // still fill the disk over a long run. Raise the cap with
  // NINJAM_FUZZ_LEAK_MAX when hunting for several distinct leaks at once.
  if (g_leak_max > 0 && !g_leak_capped)
  {
    if (count_filed_leaks() >= g_leak_max)
    {
      g_leak_capped = 1;
      char line[256];
      snprintf(line, sizeof(line),
               "LEAK: %d repros already filed in %s, not filing further findings "
               "(raise NINJAM_FUZZ_LEAK_MAX to keep filing)\n", g_leak_max, g_leak_dir);
      report_leak(line);
    }
  }
  if (g_leak_capped) return;

  WDL_SHA1 sha;
  sha.add(data, size);
  unsigned char digest[WDL_SHA1SIZE];
  sha.result(digest);

  char hex[WDL_SHA1SIZE*2+1], path[1200], line[1400];
  for (int i = 0; i < WDL_SHA1SIZE; i++) snprintf(hex + i*2, 3, "%02x", digest[i]);
  snprintf(path, sizeof(path), "%s/leak-%s", g_leak_dir, hex);

  FILE *f = fopen(path, "wb");
  if (!f)
  {
    snprintf(line, sizeof(line),
             "LEAK: %ld allocation(s) survive replaying this input twice, "
             "but could not write %s\n", residue, path);
    report_leak(line);
    return;
  }
  fwrite(data, 1, size, f);
  fclose(f);

  snprintf(line, sizeof(line),
           "LEAK: %ld allocation(s) survive replaying this input twice -> %s\n",
           residue, path);
  report_leak(line);

  // name the call sites from *this run* that are still holding memory (see
  // note_alloc); entries from before the run are skipped, and a site is only
  // listed once however many of its objects survived
  char site_line[512], seen[16][128];
  int nseen = 0;
  for (int i = 0; i < LEAK_SITE_RING && nseen < 16; i++)
  {
    int idx = (ring_mark + i) % LEAK_SITE_RING;
    if (!g_site_ptr[idx] || !g_site_ra[idx]) continue;

    // resolve here rather than storing a backtrace per allocation: this runs
    // once per finding, and the return address is still a valid code address
    Dl_info di;
    char where[160];
    if (dladdr(g_site_ra[idx], &di) && di.dli_sname)
      snprintf(where, sizeof(where), "%s", di.dli_sname);
    else
      snprintf(where, sizeof(where), "%p", g_site_ra[idx]);

    int dup = 0;
    for (int s = 0; s < nseen; s++) if (!strcmp(seen[s], where)) dup = 1;
    if (dup) continue;
    lstrcpyn_safe(seen[nseen++], where, sizeof(seen[0]));
    snprintf(site_line, sizeof(site_line), "LEAK:   live allocation %p (%lu bytes) from %s\n",
             g_site_ptr[idx], (unsigned long)g_site_size[idx], where);
    report_leak(site_line);
  }
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  if (size < 1 || size > 1<<20) return 0;

  int mark = 0;
  long first = leak_residue(data, size, &mark);
  if (first <= 0) return 0; // clean, or one-time init (not a per-input leak)

  // same residue on a second, independent execution => a real per-input leak
  int mark2 = 0;
  if (leak_residue(data, size, &mark2) == first) file_leak(data, size, first, mark2);
  return 0;
}

#else

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  return fuzz_body(data, size);
}

#endif

extern "C" int LLVMFuzzerInitialize(int *argc, char ***argv)
{
  init_archive_dir();
#ifdef NINJAM_FUZZ_LEAK_CHECK
  init_leak_dir();
#endif
  return 0;
}
