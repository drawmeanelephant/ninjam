/*
    NINJAM - tests/interval_lab.cpp

    Empirical characterization of NINJAM's interval model under adverse
    conditions. Results live in REPORT.md; tools/run_interval_lab.sh runs
    the whole matrix with one command.

    Two independent measurements are taken on the same run.

    1. CLOCK DOMAIN (interval_lab_clock.csv, no audio involved)
       Sampled synchronously for every client: where each client is inside
       its current interval, and the phase of its next interval boundary on
       its own session timeline. The interval model claims these phases
       agree across the session. They are sampled in one pass of the main
       loop, so the comparison is not skewed by sampling skew.

    2. AUDIO DOMAIN (interval_lab_markers.csv)
       Every client continuously broadcasts a short tonal burst on a local
       channel. Each client runs one matched filter per *other* client's
       code over its own output and records, for every burst it finds, the
       position on its own session timeline. A tone is used rather than a
       broadband PRBS burst because Vorbis destroys white-noise bursts: a
       PRBS marker measured perfectly in the self-test and came back at
       ~0.15 correlation after a real round trip. The tonal marker
       survives at 0.707, which is 1/sqrt(2) -- see interval_probe.h.

       So

           err(listener, emitter, k) = spos_listener(heard) - k*mark_period

       is the interval-alignment error, and its change over the run is the
       drift. The constant part is the emission-to-playback delay, which
       measurement shows to be TWO intervals plus a constant ~20 ms, not
       one: the server cannot forward an upload until the interval closes,
       and the client then holds it in a two-deep decode queue. The
       analyzer subtracts the per-pair median so only drift remains.

    A third measurement covers join-in-progress: --late-join=SEC starts an
    extra client SEC seconds into the run and the harness records, for it,
    the time to reach NJC_STATUS_OK, the time to the first audio from
    anyone, and the time to the first marker it can decode.

    Clock drift is injected by running each client's sample counter at
    (1 + ppm*1e-6) times real time. That is the honest way to model a bad
    crystal here: NJClient's entire notion of time is "one sample per
    sample handed to AudioProc", so pacing that counter is exactly a
    frequency offset.
*/

#include "interval_probe.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <chrono>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
// NOMINMAX before <windows.h>: otherwise windef.h defines min/max as
// function-like macros, and std::min(...) below expands into garbage.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <process.h>
#include <direct.h>
typedef HANDLE lab_proc_t;
#define LAB_BAD_PROC NULL
#else
#include <signal.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
typedef pid_t lab_proc_t;
#define LAB_BAD_PROC ((pid_t)-1)
#endif

#include "ninjam/njclient.h"
#include "ninjam/netcond.h"
#include "WDL/jnetlib/util.h"

#define MAX_CLIENTS 9
#define CHUNK_MAX   4800

// ---------------------------------------------------------------------------
// server process control (same shape as e2e_test.cpp)
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
  bool ok=connect(s,(struct sockaddr *)&a,sizeof(a))==0;
#ifdef _WIN32
  closesocket(s);
#else
  close(s);
#endif
  return ok;
}

// The conditioner counters are per-THREAD and cumulative, and the pump loop
// below drives every simulated client from one thread, so a plain snapshot
// would report the same grand total on every client row. Reset at the top of
// each client's pump window and fold the window into that client instead, so
// the columns are genuinely per client.
static void add_cond(NJCond::Stats &dst, const NJCond::Stats &src)
{
  dst.audio_seen += src.audio_seen;
  dst.audio_dropped += src.audio_dropped;
  dst.audio_delayed += src.audio_delayed;
  dst.audio_bytes += src.audio_bytes;
  dst.delay_applied_ms += src.delay_applied_ms;
}

// The server runs in its own process, so its downlink conditioner comes
// from the environment rather than from a thread-local profile.
static lab_proc_t spawn_server(const LabConfig &cfg, int port, const char *logpath)
{
  char portstr[16];
  snprintf(portstr,sizeof(portstr),"%d",port);
#ifdef _WIN32
  char cmd[2048];
  snprintf(cmd,sizeof(cmd),"\"%s\" \"%s\" -port %s -logfile \"%s\"",
    cfg.srvpath.c_str(),(cfg.outdir+"/server.cfg").c_str(),portstr,logpath);
  STARTUPINFOA si; PROCESS_INFORMATION pi;
  memset(&si,0,sizeof(si)); si.cb=sizeof(si);
  memset(&pi,0,sizeof(pi));
  if (!CreateProcessA(NULL,cmd,NULL,NULL,FALSE,0,NULL,NULL,&si,&pi)) return LAB_BAD_PROC;
  CloseHandle(pi.hThread);
  return pi.hProcess;
#else
  pid_t pid=fork();
  if (pid < 0) return LAB_BAD_PROC;
  if (pid == 0)
  {
    char lv[32],ld[32],lj[32];
    snprintf(lv,sizeof(lv),"%g",cfg.down_loss);
    snprintf(ld,sizeof(ld),"%g",cfg.down_delay);
    snprintf(lj,sizeof(lj),"%g",cfg.down_jitter);
    setenv("NJCOND_AUDIO_LOSS_PCT",lv,1);
    setenv("NJCOND_AUDIO_DELAY_MS",ld,1);
    setenv("NJCOND_AUDIO_JITTER_MS",lj,1);
    execl(cfg.srvpath.c_str(),cfg.srvpath.c_str(),
          (cfg.outdir+"/server.cfg").c_str(),"-port",portstr,"-logfile",logpath,(char *)NULL);
    _exit(127);
  }
  return pid;
#endif
}

static void kill_server(lab_proc_t proc)
{
  if (proc == LAB_BAD_PROC) return;
#ifdef _WIN32
  TerminateProcess(proc,0);
  WaitForSingleObject(proc,5000);
  CloseHandle(proc);
#else
  kill(proc,SIGTERM);
  waitpid(proc,NULL,0);
#endif
}

static bool write_server_config(const LabConfig &cfg, const char *path)
{
  FILE *fp=fopen(path,"w");
  if (!fp) return false;
  fprintf(fp,
    "MaxUsers %d\n"
    "MaxChannels 8 1\n"
    "AnonymousUsers multi\n"
    "AnonymousUsersCanChat yes\n"
    "AnonymousMaskIP yes\n"
    "DefaultBPM %d\n"
    "DefaultBPI %d\n"
    "SetVotingThreshold 1\n",
    cfg.nclients+4, cfg.bpm, cfg.bpi);
  fclose(fp);
  return true;
}

// ---------------------------------------------------------------------------
// simulated client
// ---------------------------------------------------------------------------

static float g_in[2][CHUNK_MAX];
static float g_out[2][CHUNK_MAX];

struct SimClient
{
  NJClient client;
  int    idx;
  double ppm;
  std::string name;

  // audio clock
  double   budget;         // fractional samples still owed
  double   t_last;         // wall time this client was last pumped
  long long processed;     // absolute output sample index of the next chunk
  long long t0;            // sample index at which this client's session position is 0
  bool     audio_started;

  // marker emission
  std::vector<float> mark;    // this client's windowed tone burst
  int    mark_freq;
  double next_k;           // session position, in seconds, of the next marker
  int    burst_rem;        // samples of a partly-written burst still owed
  int    burst_pos;
  long   markers_emitted;
  long   markers_skipped;  // emission point already passed (should stay 0)

  // detection: one matched filter per other client
  std::vector<Detector> det;

  // bookkeeping
  bool     started;
  bool     channel_made;
  double t_start_s;
  double t_connected_s;
  double t_status_ok_s;
  double t_first_remote_audio_s;
  double t_first_marker_s;
  int    first_marker_from;
  long   markers_decoded;
  long   local_markers_decoded;
  NJCond::Stats cond;

  SimClient()
    : idx(0), ppm(0.0), mark_freq(0), budget(0.0), t_last(0.0), processed(0), t0(0), audio_started(false),
      next_k(0.0), burst_rem(0), burst_pos(0), markers_emitted(0),
      markers_skipped(0), started(false), channel_made(false), t_start_s(0.0), t_connected_s(-1.0),
      t_status_ok_s(-1.0), t_first_remote_audio_s(-1.0), t_first_marker_s(-1.0),
      first_marker_from(-1), markers_decoded(0), local_markers_decoded(0), cond()
  {
    name="anon";
  }
};

static void chat_cb(void *userData, NJClient *inst, const char **parms, int nparms)
{
  (void)inst; (void)parms; (void)nparms;
  (void)userData;
}

static int license_cb(void *userData, const char *licensetext)
{
  (void)userData; (void)licensetext;
  return 1;
}

// ---------------------------------------------------------------------------
// marker record, one CSV row
// ---------------------------------------------------------------------------

struct MarkerRow
{
  double t;
  int    listener;
  int    emitter;
  long   k;
  double target_ms;
  double heard_ms;
  double peak;
  double far_peak;
  int    suspect;
};

struct ClockRow
{
  double t;
  int    idx;
  double spos_ms;
  int    ipos, ilen;
  double phase_ms;
  float  bpm;
  int    bpi;
  int    loop;
  int    nusers;
  float  remote_peak;   // loudest decoded remote channel, for join timing
};

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

static double now_s()
{
  return (double)std::chrono::duration<double>(
    std::chrono::steady_clock::now().time_since_epoch()).count();
}

// directory creation, matching the pattern in ui_snapshot.cpp: MSVC spells
// it _mkdir and takes no mode argument.
static int lab_mkdir(const char *path, int mode)
{
#ifdef _WIN32
  (void)mode;
  return _mkdir(path);
#else
  return mkdir(path,(mode_t)mode);
#endif
}

// each client gets its own work directory; NJClient scans it for cached
// remote audio and clients sharing one would trip over each other
static std::string mkdir_for(const std::string &base, int idx)
{
  char nb[32];
  snprintf(nb,sizeof(nb),"/client%d",idx);
  std::string p=base+nb;
  lab_mkdir(p.c_str(),0700);
  return p;
}

int main(int argc, char **argv)
{
  LabConfig cfg;
  if (!cfg.parse(argc,argv))
  {
    fprintf(stderr,
      "usage: ninjam_interval_lab --srv <ninjamsrv> --out <dir> --tag <name> [options]\n"
      "  --clients=N            simulated clients, default 3\n"
      "  --duration=SEC         wall seconds to measure, default 60\n"
      "  --mark-period=SEC      seconds of session time between markers, default 12\n"
      "  --mark-len=N           marker burst length in samples, default 1920\n"
      "  --bpi=N --bpm=N        server tempo, default 8/120 (4 s interval)\n"
      "  --ppm=a:b:c            per-client clock offset in ppm\n"
      "  --up-loss=PCT          drop this %% of client->server audio messages\n"
      "  --up-delay=MS --up-jitter=MS\n"
      "  --down-loss=PCT --down-delay=MS --down-jitter=MS   (applied in the server)\n"
      "  --client-delay=a:b:c   added one-way latency per client, ms, applied\n"
      "                         in BOTH directions (client->server and\n"
      "                         server->client), i.e. real symmetric RTT\n"
      "  --late-join=SEC        start one extra client SEC seconds in\n");
    return 2;
  }

  // The interval model only makes sense if markers are spaced further apart
  // than the offset they are measuring, otherwise the marker index cannot
  // be recovered from the observed position.
  const double interval_s = (double)cfg.bpi / ((double)cfg.bpm/60.0);
  if (cfg.mark_period < interval_s*2.5)
  {
    fprintf(stderr,"--mark-period must be at least 2.5x the interval (%.2f s)\n",interval_s*2.5);
    return 2;
  }

  JNL::open_socketlib();

  if (lab_mkdir(cfg.outdir.c_str(),0700) && errno != EEXIST)
  {
    fprintf(stderr,"cannot create %s\n",cfg.outdir.c_str());
    return 2;
  }

  if (!write_server_config(cfg,(cfg.outdir+"/server.cfg").c_str()))
  {
    fprintf(stderr,"cannot write server.cfg\n");
    return 2;
  }

  int port=pick_free_port();
  if (!port) { fprintf(stderr,"no free port\n"); return 2; }

  const std::string srvlog=cfg.outdir+"/server.log";
  lab_proc_t srv=spawn_server(cfg,port,srvlog.c_str());
  if (srv == LAB_BAD_PROC) { fprintf(stderr,"cannot spawn server\n"); return 2; }

  bool srvup=false;
  for (int x=0; x < 400 && !srvup; x ++)
  {
    srvup=port_accepts(port);
    if (!srvup) std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
  if (!srvup) { fprintf(stderr,"server never came up\n"); kill_server(srv); return 2; }

  char host[64];
  snprintf(host,sizeof(host),"127.0.0.1:%d",port);

  // ---- set up clients ----------------------------------------------------
  const int nslots=cfg.nclients+(cfg.late_join_at>=0.0 ? 1 : 0);
  SimClient *sc=new SimClient[nslots];
  std::vector<int> live; // slot indices that are running

  const double t_epoch=now_s();

  for (int i=0; i < cfg.nclients; i ++)
  {
    SimClient &c=sc[i];
    c.idx=i;
    c.ppm=cfg.ppm[i];
    {
      char nb[32];
      snprintf(nb,sizeof(nb),"client%d",i);
      c.name=nb;
    }

    c.client.ChatMessage_Callback=chat_cb;
    c.client.ChatMessage_User=&c;
    c.client.LicenseAgreementCallback=license_cb;
    c.client.config_savelocalaudio=-1;
    c.client.config_play_prebuffer=-1;
    c.client.config_metronome=0.0f;
    c.client.config_metronome_mute=true;
    c.client.config_autosubscribe=1;
    c.client.config_remote_autochan=1; // by channel index, so ch0 is ch0
    c.client.SetWorkDir(mkdir_for(cfg.outdir,i).c_str());

    c.mark.resize(cfg.mark_len);
    c.mark_freq=lab_mark_freq(i);
    lab_make_tone(&c.mark[0],cfg.mark_len,LAB_SRATE,c.mark_freq,cfg.amplitude);

    // the server config has AnonymousUsers, so the login name has to carry
    // the anonymous: prefix
    c.client.Connect(host,("anonymous:"+c.name).c_str(),"x");
    c.started=true;
    c.t_start_s=t_epoch;
    c.t_last=t_epoch;
    live.push_back(i);
  }

  int late_slot=-1;
  if (cfg.late_join_at >= 0.0)
  {
    late_slot=cfg.nclients;
    SimClient &c=sc[late_slot];
    c.idx=late_slot;
    c.ppm=0.0;
    {
      char nb[32];
      snprintf(nb,sizeof(nb),"late%d",late_slot);
      c.name=nb;
    }

    c.client.ChatMessage_Callback=chat_cb;
    c.client.ChatMessage_User=&c;
    c.client.LicenseAgreementCallback=license_cb;
    c.client.config_savelocalaudio=-1;
    c.client.config_play_prebuffer=-1;
    c.client.config_metronome=0.0f;
    c.client.config_metronome_mute=true;
    c.client.config_autosubscribe=1;
    c.client.config_remote_autochan=1;
    c.client.SetWorkDir(mkdir_for(cfg.outdir,late_slot).c_str());

    c.mark.resize(cfg.mark_len);
    c.mark_freq=lab_mark_freq(late_slot);
    lab_make_tone(&c.mark[0],cfg.mark_len,LAB_SRATE,c.mark_freq,cfg.amplitude);
  }

  std::vector<MarkerRow> markers;
  std::vector<ClockRow> clocks;
  std::vector<Detection> dets;
  std::vector<float> mono;

  // ---- main loop ---------------------------------------------------------
  const double t_run0=now_s();
  double t_next_probe=0.0;
  double t_next_join=t_run0+cfg.late_join_at;
  bool join_done=(cfg.late_join_at < 0.0);
  bool running=true;

  while (running)
  {
    const double t=now_s();
    const double elapsed=t-t_run0;
    if (elapsed >= cfg.duration) break;

    // late joiner
    if (!join_done && t >= t_next_join && late_slot >= 0)
    {
      SimClient &c=sc[late_slot];
      c.client.Connect(host,("anonymous:"+c.name).c_str(),"x");
      c.started=true;
      c.t_start_s=t;
      c.t_last=t;
      live.push_back(late_slot);
      join_done=true;
    }

    for (size_t si=0; si < live.size(); si ++)
    {
      SimClient &c=sc[live[si]];

      // how many samples are due at this client's own (drifted) rate
      double dt=t-c.t_last;
      c.t_last=t;
      if (dt < 0.0) dt=0.0;
      c.budget += LAB_SRATE*dt*(1.0 + c.ppm*1e-6);
      long long n=(long long)c.budget;
      c.budget -= (double)n;
      if (n > CHUNK_MAX) n=CHUNK_MAX;
      if (n < 1) continue;

      // ---- conditioner for this client only ----
      // c.idx can exceed the list for a late joiner (the list is sized to
      // the initial client count); a client that joined late has no entry,
      // which means no added latency.
      //
      // --client-delay is one-way latency applied in BOTH directions, so a
      // client's link gets cdel on the way up (TX profile) and cdel on the
      // way down (receive-side hold). The whole thing lives on the client
      // thread rather than splitting across the server: the server's receive
      // hold is a per-THREAD value (NJCond::rx_delay_ms) and the server
      // pumps every connection on its one main thread, so a per-connection
      // hold set from there would be last-wins for all of them. Each
      // simulated client has its own thread and its own connection, so the
      // client end can carry both halves exactly.
      const double cdel = c.idx < (int)cfg.client_delay.size()
        ? cfg.client_delay[c.idx] : 0.0;
      NJCond::reset_stats();
      NJCond::Profile prof;
      prof.audio_loss_pct=cfg.up_loss;
      prof.audio_delay_ms=cfg.up_delay + cdel;
      prof.audio_jitter_ms=cfg.up_jitter;
      NJCond::set_profile(prof);
      NJCond::set_rx_delay(cdel);

      // ---- network ----
      for (int r=0; r < 32; r ++)
      {
        if (c.client.Run()) break;
      }

      const int status=c.client.GetStatus();
      if (status==NJClient::NJC_STATUS_OK && c.t_status_ok_s < 0.0)
        c.t_status_ok_s=t-t_epoch;

      // first local channel, once the session is live. Set it exactly once:
      // re-declaring it every pump would spam the server with channel-info
      // messages.
      if (!c.channel_made && status==NJClient::NJC_STATUS_OK &&
          c.client.GetMaxLocalChannels() > 0)
      {
        c.client.SetLocalChannelInfo(0,"mark",true,0,true,cfg.bitrate,true,true);
        c.client.NotifyServerOfChannelChange();
        c.channel_made=true;
      }

      // ---- the edge at which this client's session clock starts ----
      // m_audio_enable is set by CONFIG_CHANGE_NOTIFY, and from then on
      // NJClient advances its session position one sample per sample
      // given to AudioProc. Sample index c.t0 is session position 0.
      if (!c.audio_started && c.client.IsAudioRunning())
      {
        c.audio_started=true;
        c.t0=c.processed;
        c.next_k=cfg.mark_period; // first marker one period in
      }

      if (!c.audio_started) { c.processed+=n; continue; }

      // ---- build the input block, inserting this client's marker bursts ----
      memset(g_in[0],0,sizeof(float)*n);
      memset(g_in[1],0,sizeof(float)*n);

      const long long sp0=c.processed;
      int i=0;

      if (c.burst_rem > 0)
      {
        // written out rather than std::min so this does not depend on
        // NOMINMAX holding for every header in the translation unit
        int w=(int)((long long)c.burst_rem < (long long)n ? c.burst_rem : n);
        for (int q=0; q < w; q ++)
          g_in[0][q]=g_in[1][q]=c.mark[c.burst_pos+q];
        c.burst_pos+=w;
        c.burst_rem-=w;
        i=w;
      }

      while (i < n)
      {
        const long long bs=c.t0+(long long)llround(c.next_k*LAB_SRATE);
        if (bs >= sp0+n) break;
        if (bs < sp0)
        {
          // the emission point went by inside a gap (only possible if a
          // chunk boundary skipped it); record it rather than hide it
          c.markers_skipped++;
          c.next_k+=cfg.mark_period;
          continue;
        }
        const int off=(int)(bs-sp0);
        int w=n-off;
        if (w > cfg.mark_len) w=cfg.mark_len;
        for (int q=0; q < w; q ++)
          g_in[0][off+q]=g_in[1][off+q]=c.mark[q];
        c.burst_pos=w;
        c.burst_rem=cfg.mark_len-w;
        c.next_k+=cfg.mark_period;
        c.markers_emitted++;
        i=n;
      }

      // ---- audio ----
      float *inp[2] = { g_in[0], g_in[1] };
      float *outp[2] = { g_out[0], g_out[1] };
      c.client.AudioProc(inp,2,outp,2,(int)n,LAB_SRATE);

      // ---- detect every other client's code in our own output ----
      mono.resize(n);
      for (int q=0; q < n; q ++) mono[q]=(g_out[0][q]+g_out[1][q])*0.5f;
      const float *monoptr=&mono[0];

      const double t_heard_ms=(double)(c.processed - c.t0)*1000.0/LAB_SRATE;
      (void)t_heard_ms;

      for (size_t e=0; e < live.size(); e ++)
      {
        const int eidx=live[e];
        if (eidx==c.idx) continue;
        if (!sc[eidx].audio_started) continue;
        if (c.det.size() <= (size_t)eidx) c.det.resize(eidx+1);
        if (c.det[eidx].D==0)
        {
          c.det[eidx].init(cfg.mark_decim,LAB_SRATE,sc[eidx].mark_freq,
                           cfg.mark_len,(float)cfg.threshold);
          // anchor the detector's decimation grid to this client's session
          // origin, so markers (which sit at session sample
          // k*mark_period*SRATE) always land on a grid boundary
          c.det[eidx].set_grid_origin(c.t0);
        }

        dets.clear();
        c.det[eidx].process(monoptr,(int)n,c.processed,dets);

        for (size_t d=0; d < dets.size(); d ++)
        {
          const Detection &dd=dets[d];
          const double heard_ms=(dd.center_sample-(double)c.t0)*1000.0/LAB_SRATE;

          // Recover which marker this was. The offset between emission and
          // playback is about one interval plus codec and network latency,
          // which is well under one mark period, so the integer part of the
          // observed position is the marker index.
          long k=(long)floor(heard_ms/(cfg.mark_period*1000.0));
          if (k < 0) k=0;

          // The detector reports the CENTRE of the correlation window, but
          // the marker is EMITTED at the start of its burst. Comparing a
          // centre against a start injects (mark_len-1)/2 samples of pure
          // measurement bias -- 19.99 ms at the default 1920, which is the
          // entire "~20 ms residual" this harness used to report. Measured
          // against k*mark_period it looks like codec or loopback latency
          // and it is not: it moves exactly in step with --mark-len.
          //
          // So compare centre to centre. k is still recovered from the
          // unshifted heard_ms, because the burst start -- not its centre --
          // is what lands on the k*mark_period grid.
          const double centre_off_ms=(double)(cfg.mark_len-1)*0.5*1000.0/(double)LAB_SRATE;
          const double target_ms=(double)k*cfg.mark_period*1000.0+centre_off_ms;
          const double frac=heard_ms-target_ms;

          // k was recovered as floor(heard/period), which is only the right
          // marker index if the emission-to-playback offset lies inside one
          // marker period. Flag anything outside that instead of quietly
          // mislabelling it.
          const int suspect = (frac < 0.0 || frac >= cfg.mark_period*1000.0) ? 1 : 0;

          MarkerRow r;
          r.t=t-t_run0;
          r.listener=c.idx;
          r.emitter=eidx;
          r.k=k;
          r.target_ms=target_ms;
          r.heard_ms=heard_ms;
          r.peak=dd.peak;
          r.far_peak=dd.far_peak;
          r.suspect=suspect;
          markers.push_back(r);

          c.markers_decoded++;
          if (c.t_first_marker_s < 0.0)
          {
            c.t_first_marker_s=t-t_epoch;
            c.first_marker_from=eidx;
          }
        }
      }

      c.processed+=n;
      add_cond(c.cond,NJCond::get_stats());
    }

    // ---- synchronous clock-domain probe ----
    if (t >= t_next_probe)
    {
      t_next_probe=t+0.1;
      for (size_t si=0; si < live.size(); si ++)
      {
        SimClient &c=sc[live[si]];
        if (!c.audio_started) continue;
        int ipos=0,ilen=0;
        c.client.GetPosition(&ipos,&ilen);
        if (ilen<1) continue;
        const double spos=(double)c.client.GetSessionPosition();
        const double ilen_ms=ilen*1000.0/LAB_SRATE;
        const double boundary=spos+(ilen-ipos)*1000.0/LAB_SRATE;
        double phase=fmod(boundary,ilen_ms);
        if (phase<0) phase+=ilen_ms;

        // loudest decoded remote channel: the first time this goes non-zero
        // is when remote audio actually started coming out of the mixer
        float peak=0.0f;
        for (int u=0; u < c.client.GetNumUsers(); u ++)
        {
          float p=c.client.GetUserChannelPeak(u,0);
          if (p>peak) peak=p;
        }
        if (peak > 0.001f && c.t_first_remote_audio_s < 0.0)
          c.t_first_remote_audio_s=t-t_epoch;

        ClockRow r;
        r.t=t-t_run0;
        r.idx=c.idx;
        r.spos_ms=spos;
        r.ipos=ipos;
        r.ilen=ilen;
        r.phase_ms=phase;
        r.bpm=c.client.GetActualBPM();
        r.bpi=c.client.GetBPI();
        r.loop=c.client.GetLoopCount();
        r.nusers=c.client.GetNumUsers();
        r.remote_peak=peak;
        clocks.push_back(r);
      }
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }

  const double t_total=now_s()-t_run0;
  NJCond::set_profile(NJCond::Profile());
  NJCond::set_rx_delay(0.0);

  // ---- write logs --------------------------------------------------------
  const std::string mp=cfg.outdir+"/"+cfg.tag+"_markers.csv";
  FILE *fp=fopen(mp.c_str(),"w");
  if (fp)
  {
    fprintf(fp,"t_s,listener,emitter,k,target_spos_ms,heard_spos_ms,err_ms,peak,far_peak,suspect\n");
    for (size_t x=0; x < markers.size(); x ++)
    {
      const MarkerRow &r=markers[x];
      fprintf(fp,"%.3f,%d,%d,%ld,%.3f,%.3f,%.3f,%.4f,%.4f,%d\n",
        r.t,r.listener,r.emitter,r.k,r.target_ms,r.heard_ms,
        r.heard_ms-r.target_ms,r.peak,r.far_peak,r.suspect);
    }
    fclose(fp);
  }

  const std::string cp=cfg.outdir+"/"+cfg.tag+"_clock.csv";
  fp=fopen(cp.c_str(),"w");
  if (fp)
  {
    fprintf(fp,"t_s,idx,spos_ms,interval_pos,interval_len,interval_phase_ms,bpm,bpi,loop,nusers,remote_peak\n");
    for (size_t x=0; x < clocks.size(); x ++)
    {
      const ClockRow &r=clocks[x];
      fprintf(fp,"%.3f,%d,%.3f,%d,%d,%.3f,%.1f,%d,%d,%d,%.5f\n",
        r.t,r.idx,r.spos_ms,r.ipos,r.ilen,r.phase_ms,r.bpm,r.bpi,r.loop,r.nusers,r.remote_peak);
    }
    fclose(fp);
  }

  const std::string sp=cfg.outdir+"/"+cfg.tag+"_summary.txt";
  fp=fopen(sp.c_str(),"w");
  if (fp)
  {
    fprintf(fp,"tag %s\n",cfg.tag.c_str());
    fprintf(fp,"nclients %d\n",cfg.nclients);
    fprintf(fp,"late_join_s %.1f\n",cfg.late_join_at);
    fprintf(fp,"bpm %d\n",cfg.bpm);
    fprintf(fp,"bpi %d\n",cfg.bpi);
    fprintf(fp,"interval_s %.4f\n",interval_s);
    fprintf(fp,"mark_period_s %.4f\n",cfg.mark_period);
    fprintf(fp,"mark_len %d\n",cfg.mark_len);
    // srate and mark_len together are what the analyzer needs to remove the
    // detector's half-burst centring bias from err_ms, so record both rather
    // than making the correction depend on a constant in the reader.
    fprintf(fp,"srate %d\n",LAB_SRATE);
    fprintf(fp,"centre_bias_ms %.6f\n",
            (double)(cfg.mark_len-1)*0.5*1000.0/(double)LAB_SRATE);
    // err_ms in these logs is ALREADY centre-to-centre (see the target_ms
    // computation), so a reader must not subtract centre_bias_ms again.
    // Older logs lack this key and DO need the bias removed.
    fprintf(fp,"err_centred 1\n");
    fprintf(fp,"decim %d\n",cfg.mark_decim);
    fprintf(fp,"threshold %.3f\n",cfg.threshold);
    fprintf(fp,"amplitude %.3f\n",cfg.amplitude);
    fprintf(fp,"bitrate %d\n",cfg.bitrate);
    fprintf(fp,"up_loss_pct %g\n",cfg.up_loss);
    fprintf(fp,"up_delay_ms %g\n",cfg.up_delay);
    fprintf(fp,"up_jitter_ms %g\n",cfg.up_jitter);
    fprintf(fp,"down_loss_pct %g\n",cfg.down_loss);
    fprintf(fp,"down_delay_ms %g\n",cfg.down_delay);
    fprintf(fp,"down_jitter_ms %g\n",cfg.down_jitter);
    fprintf(fp,"client_delay_ms %s\n",cfg.client_delay_list.c_str());
    fprintf(fp,"duration_s %.2f\n",t_total);
    fclose(fp);
  }

  // per-client outcomes as proper CSV: a flat key/value line is too easy to
  // mis-parse once there are a dozen fields
  const std::string cp2=cfg.outdir+"/"+cfg.tag+"_clients.csv";
  fp=fopen(cp2.c_str(),"w");
  if (fp)
  {
    fprintf(fp,"idx,name,ppm,is_late,status_ok_s,first_remote_audio_s,first_marker_s,"
               "first_marker_from,markers_emitted,markers_skipped,markers_decoded,"
               "audio_msgs_seen,audio_msgs_dropped,audio_msgs_delayed,final_status\n");
    for (size_t si=0; si < live.size(); si ++)
    {
      SimClient &c=sc[live[si]];
      // final_status is the NJClient status at teardown: 0 means the session
      // was still healthy at the end of the run. A fault-injection profile
      // that shows up here as a negative value has killed the session rather
      // than degraded it, which is a different (and much louder) failure than
      // anything the marker table can show.
      fprintf(fp,"%d,%s,%g,%d,%.3f,%.3f,%.3f,%d,%ld,%ld,%ld,%lu,%lu,%lu,%d\n",
        c.idx,c.name.c_str(),c.ppm,(c.idx>=cfg.nclients)?1:0,
        c.t_status_ok_s,c.t_first_remote_audio_s,c.t_first_marker_s,c.first_marker_from,
        c.markers_emitted,c.markers_skipped,c.markers_decoded,
        c.cond.audio_seen,c.cond.audio_dropped,c.cond.audio_delayed,
        c.client.GetStatus());
    }
    fclose(fp);
  }

  printf("tag=%s duration=%.1fs markers=%zu clock_rows=%zu\n",
    cfg.tag.c_str(),t_total,markers.size(),clocks.size());
  for (size_t si=0; si < live.size(); si ++)
  {
    SimClient &c=sc[live[si]];
    printf("  client %d ppm=%+g status_ok=%.2fs first_audio=%.2fs first_marker=%.2fs "
           "emitted=%ld decoded=%ld dropped=%lu/%lu\n",
      c.idx,c.ppm,c.t_status_ok_s,c.t_first_remote_audio_s,c.t_first_marker_s,
      c.markers_emitted,c.markers_decoded,
      c.cond.audio_dropped,c.cond.audio_seen);
  }
  printf("  logs: %s, %s, %s, %s\n",mp.c_str(),cp.c_str(),sp.c_str(),cp2.c_str());

  for (int i=0; i < nslots; i ++) sc[i].client.Disconnect();
  delete[] sc;
  kill_server(srv);
  JNL::close_socketlib();
  return 0;
}
