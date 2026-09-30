/*
    NINJAM - netcond.cpp

    Implementation of the adverse-conditions injector. See netcond.h for
    what is conditioned and why it is conditioned at message granularity.
*/

// stdlib.h first: mpb.h pulls in WDL/heapbuf.h, which calls malloc/free/
// realloc and does not include stdlib.h itself. Same reason the fuzzer
// needs it (see commit f32859b7).
#include <stdlib.h>
#include <math.h>

#include "netcond.h"
#include "mpb.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif

namespace NJCond
{
  static Profile &profile()
  {
    static NJCOND_THREAD_LOCAL Profile p = {0.0, 0.0, 0.0};
    return p;
  }

  // Inbound truncation, per-thread for the same reason profile() is: what a
  // connection receives is a property of the thread RUNNING it, which is what
  // makes a per-participant rate possible at all.
  static NJCOND_THREAD_LOCAL RxTrunc t_rx_trunc = {0.0, 0, 0.0, 0};

  // Receive-side hold for audio messages, in ms. Like profile(), this is
  // per-thread, but it is read by the thread that RUNS the receiving
  // connection, not the sending one: one process receives for every other
  // participant on shared threads, so "hold what I receive" must be a
  // property of the receiver. See rx_delay_ms() in netcond.h.
  static NJCOND_THREAD_LOCAL double t_rx_delay_ms = 0.0;

  static Stats &stats()
  {
    static NJCOND_THREAD_LOCAL Stats s = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0.0};
    return s;
  }

  double now_ms()
  {
#ifdef _WIN32
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
#endif
  }

  void set_profile(const Profile &p)
  {
    profile() = p;
  }

  const Profile &get_profile()
  {
    return profile();
  }

  const Stats &get_stats()
  {
    return stats();
  }

  void reset_stats()
  {
    stats() = Stats();
  }

  bool is_audio_message(int type)
  {
    switch (type)
    {
      case MESSAGE_CLIENT_UPLOAD_INTERVAL_BEGIN:
      case MESSAGE_CLIENT_UPLOAD_INTERVAL_WRITE:
      case MESSAGE_SERVER_DOWNLOAD_INTERVAL_BEGIN:
      case MESSAGE_SERVER_DOWNLOAD_INTERVAL_WRITE:
        return true;
      default:
        return false;
    }
  }

  void init_from_env()
  {
    Profile p;
    const char *s;

    if ((s=getenv("NJCOND_AUDIO_LOSS_PCT"))) p.audio_loss_pct=atof(s);
    if ((s=getenv("NJCOND_AUDIO_DELAY_MS"))) p.audio_delay_ms=atof(s);
    if ((s=getenv("NJCOND_AUDIO_JITTER_MS"))) p.audio_jitter_ms=atof(s);

    if (p.active()) profile() = p;

    RxTrunc rt=t_rx_trunc;
    if ((s=getenv("NJCOND_AUDIO_TRUNC_PCT"))) rt.trunc_pct=atof(s);
    if ((s=getenv("NJCOND_AUDIO_TRUNC_BYTES"))) rt.trunc_bytes=atoi(s);
    if ((s=getenv("NJCOND_RX_DROP_PCT"))) rt.drop_pct=atof(s);
    if ((s=getenv("NJCOND_RX_DROP_BYTES"))) rt.drop_bytes=atoi(s);

    t_rx_trunc = rt;
  }

  double rx_delay_ms()
  {
    return t_rx_delay_ms;
  }

  void set_rx_delay(double ms)
  {
    t_rx_delay_ms = ms;
  }

  void set_rx_trunc(double trunc_pct, int trunc_bytes,
                    double drop_pct, int drop_bytes)
  {
    t_rx_trunc.trunc_pct=trunc_pct;
    t_rx_trunc.trunc_bytes=trunc_bytes;
    t_rx_trunc.drop_pct=drop_pct;
    t_rx_trunc.drop_bytes=drop_bytes;
  }

  const RxTrunc &rx_trunc()
  {
    return t_rx_trunc;
  }

  // --- internals used by Net_Connection ---------------------------------

  // decide what to do with one outbound audio message.
  // returns false to drop it, otherwise the delay in ms to apply
  bool admit(int type, int size, double *delay_ms)
  {
    if (!is_audio_message(type)) return true;

    Stats &st=stats();
    st.audio_seen++;
    st.audio_bytes += (unsigned long)size;

    const Profile &pr=profile();

    if (pr.audio_loss_pct > 0.0)
    {
      double r = (double)rand() / (double)RAND_MAX * 100.0;
      if (r < pr.audio_loss_pct)
      {
        st.audio_dropped++;
        return false;
      }
    }

    double d = pr.audio_delay_ms;
    if (pr.audio_jitter_ms > 0.0)
      d += (double)rand() / (double)RAND_MAX * pr.audio_jitter_ms;

    if (d > 0.0)
    {
      st.audio_delayed++;
      st.delay_applied_ms += d;
    }

    if (delay_ms) *delay_ms = d;
    return true;
  }

  // Decide whether to roll for a truncation of one inbound message. Kept
  // separate from the two entry points below so both flavours of loss share
  // one random draw and one set of counters.
  static bool roll(double pct)
  {
    if (pct <= 0.0) return false;
    return (double)rand() / (double)RAND_MAX * 100.0 < pct;
  }

  int trunc_cut(int type, int size)
  {
    // only a WRITE carries audio; a BEGIN is interval metadata and cutting
    // its tail would corrupt fields rather than drop samples
    if (type != MESSAGE_SERVER_DOWNLOAD_INTERVAL_WRITE &&
        type != MESSAGE_CLIENT_UPLOAD_INTERVAL_WRITE)
      return 0;

    const RxTrunc &rt=t_rx_trunc;
    if (!roll(rt.trunc_pct) || rt.trunc_bytes < 1) return 0;

    // never eat the framing: what is being modelled is a short write, not a
    // header the peer cannot parse. Clamping also keeps a small payload from
    // turning into the separate case parse() rejects outright.
    int cut=rt.trunc_bytes;
    const int payload=size-AUDIO_WRITE_HEADER;
    if (cut > payload) cut=payload;
    if (cut < 1) return 0;

    Stats &st=stats();
    st.audio_truncated++;
    st.trunc_bytes += (unsigned long)cut;
    st.trunc_msg_bytes += (unsigned long)size;
    return cut;
  }

  int rx_byte_drop(int type)
  {
    if (!is_audio_message(type)) return 0;

    const RxTrunc &rt=t_rx_trunc;
    if (!roll(rt.drop_pct) || rt.drop_bytes < 1) return 0;

    Stats &st=stats();
    st.rx_dropped++;
    st.drop_bytes += (unsigned long)rt.drop_bytes;
    return rt.drop_bytes;
  }
}
