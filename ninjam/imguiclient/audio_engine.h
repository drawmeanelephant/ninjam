/*
    NINJAM client - audio_engine.h

    Thin duplex audio I/O wrapper around miniaudio. The callback receives and
    returns planar (non-interleaved) float buffers, matching the
    NJClient::AudioProc convention, and is invoked from the audio thread.
*/

#ifndef _AUDIO_ENGINE_H_
#define _AUDIO_ENGINE_H_

typedef void (*AudioEngineProc)(float **inbuf, int innch, float **outbuf, int outnch, int len, int srate, void *user);

class AudioEngine
{
public:
  AudioEngine();
  ~AudioEngine();

  bool Start(int srate, int innch, int outnch, AudioEngineProc proc, void *user);
  void Stop();

  bool IsRunning() const { return m_running; }
  int GetSampleRate() const { return m_srate; }
  const char *GetError() const { return m_err; }

  // called by the audio device callback only
  void OnAudio(const float *ininterleaved, float *outinterleaved, int frames);

private:
  struct Impl;
  Impl *m_impl;

  AudioEngineProc m_proc;
  void *m_user;
  int m_srate, m_innch, m_outnch;
  bool m_running;
  char m_err[256];
};

#endif
