/*
    NINJAM client - audio_engine.cpp
*/

#include <stdio.h>
#include <string.h>

#include "miniaudio.h"

#include "audio_engine.h"

#define AE_MAX_CHANNELS 8
#define AE_CHUNK_FRAMES 512

struct AudioEngine::Impl
{
  ma_device dev;
  bool dev_inited;

  // scratch planar buffers, processed in bounded chunks
  float in_planar[AE_MAX_CHANNELS][AE_CHUNK_FRAMES];
  float out_planar[AE_MAX_CHANNELS][AE_CHUNK_FRAMES];
  float *in_ptrs[AE_MAX_CHANNELS];
  float *out_ptrs[AE_MAX_CHANNELS];
};

static void ae_data_callback(ma_device *dev, void *out, const void *in, ma_uint32 frames)
{
  AudioEngine *ae=(AudioEngine *)dev->pUserData;
  if (ae) ae->OnAudio((const float *)in,(float *)out,(int)frames);
}

AudioEngine::AudioEngine()
{
  m_impl=new Impl;
  memset(&m_impl->dev,0,sizeof(m_impl->dev));
  m_impl->dev_inited=false;
  m_proc=0;
  m_user=0;
  m_srate=48000;
  m_innch=m_outnch=2;
  m_running=false;
  m_err[0]=0;
}

AudioEngine::~AudioEngine()
{
  Stop();
  delete m_impl;
}

bool AudioEngine::Start(int srate, int innch, int outnch, AudioEngineProc proc, void *user)
{
  Stop();
  if (!proc || srate < 8000 || innch < 1 || outnch < 1 ||
      innch > AE_MAX_CHANNELS || outnch > AE_MAX_CHANNELS)
  {
    snprintf(m_err,sizeof(m_err),"invalid audio configuration");
    return false;
  }

  m_proc=proc;
  m_user=user;
  m_srate=srate;
  m_innch=innch;
  m_outnch=outnch;

  ma_device_config cfg=ma_device_config_init(ma_device_type_duplex);
  cfg.capture.format=ma_format_f32;
  cfg.capture.channels=(ma_uint32)innch;
  cfg.playback.format=ma_format_f32;
  cfg.playback.channels=(ma_uint32)outnch;
  cfg.sampleRate=(ma_uint32)srate;
  cfg.periodSizeInFrames=AE_CHUNK_FRAMES;
  cfg.dataCallback=ae_data_callback;
  cfg.pUserData=this;

  if (ma_device_init(NULL,&cfg,&m_impl->dev) != MA_SUCCESS)
  {
    snprintf(m_err,sizeof(m_err),"audio device init failed");
    m_proc=0;
    return false;
  }
  m_impl->dev_inited=true;

  if (ma_device_start(&m_impl->dev) != MA_SUCCESS)
  {
    snprintf(m_err,sizeof(m_err),"audio device start failed");
    ma_device_uninit(&m_impl->dev);
    m_impl->dev_inited=false;
    m_proc=0;
    return false;
  }

  m_running=true;
  m_err[0]=0;
  return true;
}

void AudioEngine::Stop()
{
  if (m_impl->dev_inited)
  {
    ma_device_uninit(&m_impl->dev); // stops the device first
    m_impl->dev_inited=false;
  }
  m_running=false;
}

void AudioEngine::OnAudio(const float *ininterleaved, float *outinterleaved, int frames)
{
  if (!m_proc) return;

  int pos=0;
  while (pos < frames)
  {
    int n=frames-pos;
    if (n > AE_CHUNK_FRAMES) n=AE_CHUNK_FRAMES;

    int c;
    for (c = 0; c < m_innch; c ++)
      m_impl->in_ptrs[c]=m_impl->in_planar[c];
    for (c = 0; c < m_outnch; c ++)
    {
      m_impl->out_ptrs[c]=m_impl->out_planar[c];
      memset(m_impl->out_planar[c],0,sizeof(float)*n);
    }

    if (ininterleaved)
    {
      const float *ip=ininterleaved+(size_t)pos*m_innch;
      int x;
      for (x = 0; x < n; x ++)
        for (c = 0; c < m_innch; c ++)
          m_impl->in_planar[c][x]=*ip++;
    }
    else
    {
      // capture unavailable: feed silence rather than stale samples
      for (c = 0; c < m_innch; c ++)
        memset(m_impl->in_planar[c],0,sizeof(float)*n);
    }

    m_proc(m_impl->in_ptrs,m_innch,m_impl->out_ptrs,m_outnch,n,m_srate,m_user);

    float *op=outinterleaved+(size_t)pos*m_outnch;
    int x;
    for (x = 0; x < n; x ++)
      for (c = 0; c < m_outnch; c ++)
        *op++=m_impl->out_planar[c][x];

    pos+=n;
  }
}
