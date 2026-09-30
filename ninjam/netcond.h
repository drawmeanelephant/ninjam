/*
    NINJAM - netcond.h

    Emulated adverse network conditions for the interval-model experiments
    (see ninjam/tests/interval_lab.cpp and REPORT.md).

    NINJAM's transport is a single TCP stream (WDL/jnetlib), so IP-level
    packet loss is not something a client can observe: TCP retransmits and
    the only thing a lost packet becomes is extra delay. The unit that
    actually matters to the interval model is the Net_Message, so that is
    what this conditions. Audio payloads travel as

        MESSAGE_CLIENT_UPLOAD_INTERVAL_BEGIN  (client -> server)
        MESSAGE_CLIENT_UPLOAD_INTERVAL_WRITE
        MESSAGE_SERVER_DOWNLOAD_INTERVAL_BEGIN (server -> client)
        MESSAGE_SERVER_DOWNLOAD_INTERVAL_WRITE

    and everything else (auth, masks, channel info, config/BPM) is left
    alone, because losing those tears down the session rather than
    degrading it.

    The profile is thread-local. The lab harness runs every simulated
    client on its own thread, so each one can carry a different loss /
    jitter profile in a single process. A standalone process (the server)
    picks its profile up from the NJCOND_* environment variables in
    init_from_env().

    Message loss is the mild case, not the only one (issue #23). A write
    can also arrive SHORT -- intact as a message, with the tail of its
    audio payload missing -- which the protocol accepts silently, because
    the payload length is simply whatever the message says it is
    (mpb_server_download_interval_write::parse derives audio_data_len from
    the message size, with no length to check it against). A byte stream
    truncated in the MIDDLE of a message is a third and quite different
    case: the framing is a bare type plus 32 bit length with no resync
    marker, so one lost byte misaligns every message after it. Both are
    injected here, on the receive side, and they behave nothing alike.

    This header is always compiled in but is inert unless a profile is
    set, so normal builds are unaffected.
*/

#ifndef _NETCOND_H_
#define _NETCOND_H_

// per-thread state, so every simulated client in one process can carry its
// own profile
#if defined(_MSC_VER)
#define NJCOND_THREAD_LOCAL __declspec(thread)
#else
#define NJCOND_THREAD_LOCAL __thread
#endif

namespace NJCond
{
  // Note: these are plain aggregates with no user-declared constructor, so
  // that the per-thread instances below can be constant-initialised (C++
  // requires a constant initialiser for thread_local).

  struct Profile
  {
    double audio_loss_pct;   // percent of audio messages to drop, 0..100
    double audio_delay_ms;   // constant extra delay applied to audio messages
    double audio_jitter_ms;  // uniform random extra delay in [0, this]

    bool active() const
    {
      return audio_loss_pct > 0.0 || audio_delay_ms > 0.0 || audio_jitter_ms > 0.0;
    }
  };

  // Truncation of the inbound stream, the other way an audio message can go
  // missing besides being dropped whole (issue #23). It lives outside Profile
  // because it is receive-side only, like rx_delay_ms() below, and because
  // Profile is a plain aggregate that a caller is expected to fill in
  // completely -- an unmentioned field there is a bug waiting to happen.
  //
  // trunc_pct / trunc_bytes model a SHORT message: intact framing, the tail
  // of the audio payload missing. The peer cannot tell it from a complete
  // write, because the payload length is simply whatever the message claims.
  //
  // drop_pct / drop_bytes model a truncated BYTE STREAM: N bytes vanish from
  // the middle of a message body, so the length-prefixed framing that follows
  // is misaligned and there is no resync marker to recover it with. The two
  // are not variations on the same fault; they fail differently.
  struct RxTrunc
  {
    double trunc_pct;
    int    trunc_bytes;
    double drop_pct;
    int    drop_bytes;
  };

  void set_rx_trunc(double trunc_pct, int trunc_bytes,
                    double drop_pct, int drop_bytes);
  const RxTrunc &rx_trunc();

  // Bytes of framing in front of the audio payload of an INTERVAL_WRITE: a
  // 16 byte guid plus a 1 byte flags field, the last bit of which marks the
  // final write of an interval. See
  // mpb_server_download_interval_write::parse (ninjam/mpb.cpp).
  enum { AUDIO_WRITE_HEADER = 17 };

  struct Stats
  {
    unsigned long audio_seen;      // audio messages offered to Send()
    unsigned long audio_dropped;   // dropped by the loss filter
    unsigned long audio_delayed;   // held back by the delay/jitter filter
    unsigned long audio_bytes;     // total bytes of audio messages seen
    unsigned long audio_truncated; // inbound audio writes shortened
    unsigned long trunc_bytes;     // bytes removed by shortening
    unsigned long trunc_msg_bytes; // total size of the messages that were cut
    unsigned long rx_dropped;      // inbound audio messages cut mid-body
    unsigned long drop_bytes;      // bytes lost off the wire that way
    double delay_applied_ms;       // sum of all delays applied (for mean)
  };

  // monotonic milliseconds; the delay queue's clock base
  double now_ms();

  void set_profile(const Profile &p);
  const Profile &get_profile();

  // counters for the calling thread
  const Stats &get_stats();
  void reset_stats();

  // read NJCOND_AUDIO_LOSS_PCT / NJCOND_AUDIO_DELAY_MS / NJCOND_AUDIO_JITTER_MS
  // into the calling thread's profile, and NJCOND_AUDIO_TRUNC_PCT /
  // NJCOND_AUDIO_TRUNC_BYTES / NJCOND_RX_DROP_PCT / NJCOND_RX_DROP_BYTES into
  // its truncation state. No-op for whatever is unset.
  void init_from_env();

  // Truncation rolls, called by Net_Connection::Run for each inbound audio
  // message. Both are receive-side: what a truncation models is what the
  // receiver ended up with, and the receive side is also the only place a
  // per-participant value can be applied (see rx_delay_ms() on why the send
  // side cannot carry one).
  //
  // trunc_cut returns how many bytes to remove from the TAIL of an inbound
  // message's audio payload, 0 to deliver it intact. Only INTERVAL_WRITE
  // messages have an audio payload, and the cut never eats the 17 byte
  // header, so the result is always a well-formed short write.
  int trunc_cut(int type, int size);

  // rx_byte_drop returns how many bytes to discard from the front of an
  // inbound audio message's BODY, 0 not to. The caller must only apply a
  // non-zero result when at least that many body bytes are already buffered,
  // so the loss can never land on a message boundary by accident.
  int rx_byte_drop(int type);

  // The delay/jitter profile (audio_delay_ms / audio_jitter_ms) is applied
  // where messages are SENT, on the sending thread. Symmetric per-link
  // latency also needs the receiving end held, which that path cannot do: a
  // process receives on behalf of every other participant, all on shared
  // threads, so "hold what I receive for X ms" must be a property of the
  // thread RUNNING the receiving connection. Net_Connection::Run reads this
  // for every completed audio message it parks, so the value applies to
  // whatever connection(s) that thread drives.
  //
  // This is per-THREAD, not per-connection, which is exactly why it works
  // for the interval lab: every simulated client is pumped on its own thread
  // with its own connection, so one client sets it and only that client sees
  // it. It cannot give two connections on the SAME thread different holds,
  // so the lab applies a link's full one-way delay from the client end
  // rather than splitting it across a shared server thread (see
  // --client-delay in tests/interval_lab.cpp).
  double rx_delay_ms();

  // set this thread's receive-side hold for audio messages, in ms. 0.0 (the
  // default) disables it.
  void set_rx_delay(double ms);

  // true if the message type carries interval audio
  bool is_audio_message(int type);

  // Called by Net_Connection::Send for every outbound message. Non-audio
  // messages always pass through with zero delay. For audio messages this
  // rolls the loss filter and then the delay/jitter filter: it returns
  // false to drop the message, or true with *delay_ms set to how long the
  // message should be held before it is allowed onto the wire.
  bool admit(int type, int size, double *delay_ms);
}

#endif//_NETCOND_H_
