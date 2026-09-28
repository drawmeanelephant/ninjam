/*
    NINJAM - tests/e2e_test.cpp

    End-to-end test: boots ninjamsrv on a free local port, connects two
    headless NJClient instances ("anonymous:alice" / "anonymous:bob") and
    verifies:

      1. connect + auth (both reach NJC_STATUS_OK)
      2. the user lists show both users
      3. chat: alice's MSG is relayed to bob
      4. one interval round-trip: alice broadcasts a local channel, the
         server relays it, and bob decodes real audio energy from it

    Everything runs in "virtual time": NJClient clocks advance per audio
    sample, so the test pumps AudioProc() as fast as it likes and only
    sleeps to let the localhost transport catch up.

    Usage: ninjam_e2e <path-to-ninjamsrv>
*/

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <chrono>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <process.h>
typedef HANDLE e2e_proc_t;
#define E2E_BAD_PROC NULL
#else
#include <signal.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
typedef pid_t e2e_proc_t;
#define E2E_BAD_PROC ((pid_t)-1)
#endif

#include "ninjam/njclient.h"
#include "ninjam/imguiclient/auto_reconnect.h"
#include "WDL/jnetlib/util.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static int g_checks=0, g_failures=0;

#define CHECK(cond) do { \
    g_checks++; \
    if (!(cond)) { g_failures++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

// ---------------------------------------------------------------------------
// test client wrapper
// ---------------------------------------------------------------------------

struct TestClient
{
  NJClient client;
  std::vector<std::string> chat;
};

static void chat_cb(void *userData, NJClient *inst, const char **parms, int nparms)
{
  (void)inst;
  TestClient *tc=(TestClient *)userData;
  std::string line;
  for (int x = 0; x < nparms; x ++)
  {
    if (x) line+=" ";
    if (parms[x]) line+=parms[x];
  }
  tc->chat.push_back(line);
}

static int license_cb(void *userData, const char *licensetext)
{
  (void)userData; (void)licensetext;
  return 1; // accept automatically
}

static void init_client(TestClient &tc)
{
  tc.client.ChatMessage_Callback=chat_cb;
  tc.client.ChatMessage_User=&tc;
  tc.client.LicenseAgreementCallback=license_cb;
  tc.client.config_savelocalaudio=-1; // delete remote .oggs as soon as possible
  tc.client.config_play_prebuffer=-1; // play decoded audio immediately
  tc.client.config_metronome=0.0f;
  tc.client.config_metronome_mute=true;
}

// returns nonzero if sleep is OK
static int pump(TestClient &tc)
{
  int sleepok=tc.client.Run();
  for (int spins = 0; !sleepok && spins < 64; spins ++) sleepok=tc.client.Run();
  return sleepok;
}

static bool chat_contains(const TestClient &tc, const char *text)
{
  for (size_t x = 0; x < tc.chat.size(); x ++)
    if (tc.chat[x].find(text) != std::string::npos) return true;
  return false;
}

static double feed_audio(TestClient &tc, double *phase, double freq, double amp);

static bool wait_for_bpi(TestClient &a, TestClient &b, int bpi, int timeout_seconds=5)
{
  auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(timeout_seconds);
  while (std::chrono::steady_clock::now() < deadline)
  {
    pump(a);
    pump(b);
    feed_audio(a,NULL,0.0,0.0);
    feed_audio(b,NULL,0.0,0.0);
    if (a.client.GetBPI()==bpi && b.client.GetBPI()==bpi) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return false;
}

static bool wait_for_chat(TestClient &a, TestClient &b, const char *text, int timeout_seconds=5)
{
  auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(timeout_seconds);
  while (std::chrono::steady_clock::now() < deadline)
  {
    pump(a);
    pump(b);
    if (chat_contains(a,text) || chat_contains(b,text)) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return false;
}

// ---------------------------------------------------------------------------
// audio pumping
// ---------------------------------------------------------------------------

#define E2E_CHUNK 4800
#define E2E_SRATE 48000

static float s_in[2][E2E_CHUNK], s_out[2][E2E_CHUNK];
static float *s_ins[2]={ s_in[0], s_in[1] };
static float *s_outs[2]={ s_out[0], s_out[1] };

// feeds one chunk of audio through a client; returns output energy
static double feed_audio(TestClient &tc, double *phase, double freq, double amp)
{
  int x;
  for (x = 0; x < E2E_CHUNK; x ++)
  {
    double v=phase ? amp*sin(*phase) : 0.0;
    if (phase)
    {
      *phase+=2.0*M_PI*freq/(double)E2E_SRATE;
      if (*phase > 2.0*M_PI) *phase-=2.0*M_PI;
    }
    s_in[0][x]=(float)v;
    s_in[1][x]=(float)v;
    s_out[0][x]=s_out[1][x]=0.0f;
  }
  tc.client.AudioProc(s_ins,2,s_outs,2,E2E_CHUNK,E2E_SRATE);

  double energy=0.0;
  for (x = 0; x < E2E_CHUNK; x ++) energy+=(double)s_out[0][x]*(double)s_out[0][x];
  return energy;
}

// ---------------------------------------------------------------------------
// server process control
// ---------------------------------------------------------------------------

static int pick_free_port()
{
  int s=(int)socket(AF_INET,SOCK_STREAM,0);
  if (s < 0) return 0;
  struct sockaddr_in a;
  memset(&a,0,sizeof(a));
  a.sin_family=AF_INET;
  a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
  a.sin_port=0;
  int port=0;
  if (!bind(s,(struct sockaddr *)&a,sizeof(a)))
  {
    socklen_t len=sizeof(a);
    if (!getsockname(s,(struct sockaddr *)&a,&len)) port=ntohs(a.sin_port);
  }
#ifdef _WIN32
  closesocket(s);
#else
  close(s);
#endif
  return port;
}

static bool port_accepts(int port)
{
  int s=(int)socket(AF_INET,SOCK_STREAM,0);
  if (s < 0) return false;
  struct sockaddr_in a;
  memset(&a,0,sizeof(a));
  a.sin_family=AF_INET;
  a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
  a.sin_port=htons((unsigned short)port);
  bool ok=connect(s,(struct sockaddr *)&a,sizeof(a)) == 0;
#ifdef _WIN32
  closesocket(s);
#else
  close(s);
#endif
  return ok;
}

static e2e_proc_t spawn_server(const char *srvpath, const char *cfgpath, int port, const char *logpath)
{
  char portstr[16];
  snprintf(portstr,sizeof(portstr),"%d",port);
#ifdef _WIN32
  char cmd[2048];
  snprintf(cmd,sizeof(cmd),"\"%s\" \"%s\" -port %s -logfile \"%s\"",srvpath,cfgpath,portstr,logpath);
  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  memset(&si,0,sizeof(si));
  si.cb=sizeof(si);
  memset(&pi,0,sizeof(pi));
  if (!CreateProcessA(NULL,cmd,NULL,NULL,FALSE,0,NULL,NULL,&si,&pi)) return E2E_BAD_PROC;
  CloseHandle(pi.hThread);
  return pi.hProcess;
#else
  pid_t pid=fork();
  if (pid < 0) return E2E_BAD_PROC;
  if (pid == 0)
  {
    execl(srvpath,srvpath,cfgpath,"-port",portstr,"-logfile",logpath,(char *)NULL);
    _exit(127);
  }
  return pid;
#endif
}

static void kill_server(e2e_proc_t proc)
{
  if (proc == E2E_BAD_PROC) return;
#ifdef _WIN32
  TerminateProcess(proc,0);
  WaitForSingleObject(proc,5000);
  CloseHandle(proc);
#else
  kill(proc,SIGTERM);
  waitpid(proc,NULL,0);
#endif
}

static bool write_test_server_config(const char *path, int default_bpi)
{
  FILE *fp=fopen(path,"w");
  if (!fp) return false;
  fprintf(fp,
    "MaxUsers 10\n"
    "MaxChannels 8 2\n"
    "AnonymousUsers multi\n"
    "AnonymousUsersCanChat yes\n"
    "AnonymousMaskIP yes\n"
    "User alice test TCV\n"
    "DefaultBPI %d\n"
    "SetVotingThreshold 1\n",default_bpi);
  fclose(fp);
  return true;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(int argc, char **argv)
{
  if (argc < 2)
  {
    printf("usage: ninjam_e2e <path-to-ninjamsrv>\n");
    return 2;
  }
  const char *srvpath=argv[1];

  JNL::open_socketlib();

  // server config: anonymous users, no license prompt
  const char *cfgpath="ninjam_e2e.cfg";
  const char *logpath="ninjam_e2e_server.log";
  const char *workdir="ninjam_e2e_work";
  if (!write_test_server_config(cfgpath,128))
  {
    printf("cannot write %s\n",cfgpath);
    return 2;
  }
#ifdef _WIN32
  CreateDirectoryA(workdir,NULL);
#else
  mkdir(workdir,0700);
#endif

  int port=pick_free_port();
  if (!port) { printf("could not pick a free port\n"); return 2; }

  e2e_proc_t srv=spawn_server(srvpath,cfgpath,port,logpath);
  if (srv == E2E_BAD_PROC) { printf("failed to spawn %s\n",srvpath); return 2; }

  bool srvup=false;
  for (int x = 0; x < 200 && !srvup; x ++)
  {
    srvup=port_accepts(port);
    if (!srvup) std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
  CHECK(srvup);
  if (!srvup)
  {
    kill_server(srv);
    return 1;
  }

  char host[64];
  snprintf(host,sizeof(host),"127.0.0.1:%d",port);

  TestClient alice, bob;
  init_client(alice);
  init_client(bob);
  alice.client.SetWorkDir(workdir);
  bob.client.SetWorkDir(workdir);

  AutoReconnect reconnect;
  reconnect.set_enabled(true,AutoReconnect::STATUS_PRECONNECT,0.0);
  reconnect.manual_connect();
  const auto reconnect_clock=std::chrono::steady_clock::now();
  alice.client.Connect(host,"alice","test");
  bob.client.Connect(host,"anonymous:bob","x");

  // phase 1: connect + auth
  bool alice_ok=false, bob_ok=false;
  auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(15);
  while ((!alice_ok || !bob_ok) && std::chrono::steady_clock::now() < deadline)
  {
    pump(alice);
    pump(bob);
    reconnect.observe(alice.client.GetStatus(),
      std::chrono::duration<double>(std::chrono::steady_clock::now()-reconnect_clock).count());
    alice_ok=alice.client.GetStatus() == NJClient::NJC_STATUS_OK;
    bob_ok=bob.client.GetStatus() == NJClient::NJC_STATUS_OK;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  CHECK(alice_ok);
  CHECK(bob_ok);

  if (alice_ok && bob_ok)
  {
    // The server config and vote parser both accept the new maximum BPI.
    CHECK(wait_for_bpi(alice,bob,128));
    alice.client.ChatMessage_Send("MSG","!vote bpi 64");
    CHECK(wait_for_chat(alice,bob,"setting BPI to 64"));
    alice.client.ChatMessage_Send("MSG","!vote bpi 128");
    CHECK(wait_for_chat(alice,bob,"setting BPI to 128"));
    alice.client.ChatMessage_Send("MSG","!vote bpi 8");
    CHECK(wait_for_chat(alice,bob,"setting BPI to 8"));

    // Start a fresh session at a normal interval length for the audio roundtrip.
    kill_server(srv);
    srv=E2E_BAD_PROC;
    alice.client.Disconnect();
    bob.client.Disconnect();
    CHECK(write_test_server_config(cfgpath,8));
    srv=spawn_server(srvpath,cfgpath,port,logpath);
    CHECK(srv != E2E_BAD_PROC);
    bool bpi_test_srv_restarted=false;
    for (int x = 0; x < 200 && !bpi_test_srv_restarted; x ++)
    {
      bpi_test_srv_restarted=port_accepts(port);
      if (!bpi_test_srv_restarted) std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    CHECK(bpi_test_srv_restarted);

    reconnect.manual_connect();
    alice.client.Connect(host,"alice","test");
    bob.client.Connect(host,"anonymous:bob","x");
    alice_ok=false;
    bob_ok=false;
    deadline=std::chrono::steady_clock::now()+std::chrono::seconds(15);
    while ((!alice_ok || !bob_ok) && std::chrono::steady_clock::now() < deadline)
    {
      pump(alice);
      pump(bob);
      reconnect.observe(alice.client.GetStatus(),
        std::chrono::duration<double>(std::chrono::steady_clock::now()-reconnect_clock).count());
      alice_ok=alice.client.GetStatus() == NJClient::NJC_STATUS_OK;
      bob_ok=bob.client.GetStatus() == NJClient::NJC_STATUS_OK;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    CHECK(alice_ok);
    CHECK(bob_ok);
    CHECK(wait_for_bpi(alice,bob,8));

    // phase 2: each user list shows the other user (the server never sends
    // you your own entry -- SendUserList() skips u == this)
    int alice_idx=-1, bob_seen=0, alice_seen=0;
    deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while ((!alice_seen || !bob_seen) && std::chrono::steady_clock::now() < deadline)
    {
      pump(alice);
      pump(bob);
      for (int u = 0; u < bob.client.GetNumUsers(); u ++)
      {
        const char *nm=bob.client.GetUserState(u);
        if (nm && !strncmp(nm,"alice",5)) { alice_seen=1; alice_idx=u; }
      }
      for (int u = 0; u < alice.client.GetNumUsers(); u ++)
      {
        const char *nm=alice.client.GetUserState(u);
        if (nm && !strncmp(nm,"bob",3)) bob_seen=1;
      }
      if (!alice_seen || !bob_seen) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    CHECK(alice_seen);
    CHECK(bob_seen);

    // phase 3: chat relay
    alice.client.ChatMessage_Send("MSG","hello\nfrom alice");
    deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    bool chat_ok=chat_contains(bob,"MSG alice hello from alice");
    while (!chat_ok && std::chrono::steady_clock::now() < deadline)
    {
      pump(alice);
      pump(bob);
      chat_ok=chat_contains(bob,"MSG alice hello from alice");
      if (!chat_ok) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    CHECK(chat_ok);

    alice.client.ChatMessage_Send("PRIVMSG","bob","private\nline");
    deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    bool private_ok=chat_contains(bob,"PRIVMSG alice private line");
    while (!private_ok && std::chrono::steady_clock::now() < deadline)
    {
      pump(alice);
      pump(bob);
      private_ok=chat_contains(bob,"PRIVMSG alice private line");
      if (!private_ok) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    CHECK(private_ok);

    alice.client.ChatMessage_Send("ADMIN","topic first\nsecond");
    deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    bool topic_ok=chat_contains(bob,"TOPIC alice first second");
    while (!topic_ok && std::chrono::steady_clock::now() < deadline)
    {
      pump(alice);
      pump(bob);
      topic_ok=chat_contains(bob,"TOPIC alice first second");
      if (!topic_ok) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    CHECK(topic_ok);

    // phase 4: interval round-trip.
    // alice broadcasts a 440Hz tone on a local channel; bob should decode it.
    alice.client.SetLocalChannelInfo(0,"e2e",true,0,true,64,true,true);
    alice.client.NotifyServerOfChannelChange();

    double aphase=0.0;
    double bob_rx_energy=0.0;
    bool chan_seen=false, peak_seen=false;
    int interval_chunks=(int)((60.0*alice.client.GetBPI()/alice.client.GetActualBPM())*(double)E2E_SRATE/E2E_CHUNK)+1;

    deadline=std::chrono::steady_clock::now()+std::chrono::seconds(30);
    int fed=0;
    while (std::chrono::steady_clock::now() < deadline)
    {
      feed_audio(alice,&aphase,440.0,0.5); // alice transmits
      fed++;
      bob_rx_energy+=feed_audio(bob,NULL,0.0,0.0); // bob listens

      pump(alice);
      pump(bob);

      if ((fed&7) == 0) std::this_thread::sleep_for(std::chrono::milliseconds(2));

      // bob sees alice's channel appear
      if (!chan_seen && alice_idx >= 0 && bob.client.EnumUserChannels(alice_idx,0) >= 0)
      {
        chan_seen=true;
        // make sure it is subscribed
        int ch=bob.client.EnumUserChannels(alice_idx,0);
        bob.client.SetUserChannelState(alice_idx,ch,true,true,false,0,false,0,false,false,false,false);
      }
      if (chan_seen && !peak_seen && bob.client.GetUserChannelPeak(alice_idx,0) > 1e-4)
        peak_seen=true;

      if (peak_seen && bob_rx_energy > 1e-4 && fed > 2*interval_chunks) break;
    }
    CHECK(chan_seen);
    CHECK(peak_seen);
    CHECK(bob_rx_energy > 1e-4);

    // Restart the server and verify that an unexpected disconnect is retried.
    kill_server(srv);
    srv=E2E_BAD_PROC;
    bool dropped=false;
    deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while (!dropped && std::chrono::steady_clock::now() < deadline)
    {
      pump(alice);
      pump(bob);
      const double now=std::chrono::duration<double>(
        std::chrono::steady_clock::now()-reconnect_clock).count();
      reconnect.observe(alice.client.GetStatus(),now);
      const int status=alice.client.GetStatus();
      dropped=status==NJClient::NJC_STATUS_DISCONNECTED ||
              status==NJClient::NJC_STATUS_CANTCONNECT;
      if (!dropped) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    CHECK(dropped);

    srv=spawn_server(srvpath,cfgpath,port,logpath);
    CHECK(srv != E2E_BAD_PROC);
    bool srv_restarted=false;
    for (int x = 0; x < 200 && !srv_restarted; x ++)
    {
      srv_restarted=port_accepts(port);
      if (!srv_restarted) std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    CHECK(srv_restarted);

    bool recovered=false;
    deadline=std::chrono::steady_clock::now()+std::chrono::seconds(30);
    while (!recovered && std::chrono::steady_clock::now() < deadline)
    {
      pump(alice);
      pump(bob);
      const double now=std::chrono::duration<double>(
        std::chrono::steady_clock::now()-reconnect_clock).count();
      reconnect.observe(alice.client.GetStatus(),now);
      if (reconnect.begin_retry(now))
        alice.client.Connect(host,"alice","test");
      recovered=alice.client.GetStatus()==NJClient::NJC_STATUS_OK;
      if (!recovered) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    CHECK(recovered);
  }

  alice.client.Disconnect();
  bob.client.Disconnect();
  kill_server(srv);
  JNL::close_socketlib();

  printf("%d checks, %d failures\n",g_checks,g_failures);
  return g_failures ? 1 : 0;
}
