/*
    NINJAM - tests/interval_probe.h

    Shared machinery for the interval-model experiments
    (see tests/interval_lab.cpp and REPORT.md).

    THE MEASUREMENT
    ---------------
    Every client continuously broadcasts a short marker on a local
    channel. Each listener runs one Detector per *other* client over its
    own output and records, for every marker it finds, the position on
    its OWN session timeline.

    A client's session timeline is its own sample counter: NJClient
    advances m_session_pos by exactly one sample per sample handed to
    AudioProc, and only once the server has told it audio is enabled
    (m_audio_enable is set by CONFIG_CHANGE_NOTIFY). So the session
    position of absolute sample index X on client c is

        spos(X) = (X - c.t0) / SRATE

    where c.t0 is the sample index at which audio first ran. There is no
    shared time origin anywhere in the protocol -- the server never sends
    an absolute time reference -- so spos() is only ever meaningful when
    compared against another client's spos().

    WHY A TONE AND NOT A PRBS
    --------------------------
    The first version of this used a broadband PRBS burst. It measured
    fine in isolation (see probe_selftest.cpp) but came back at a
    correlation of ~0.15 after a real round trip: the wire format is
    Vorbis, and a 20 ms white-noise burst is close to the worst input a
    perceptual codec can be given. The audio was arriving (remote peak
    0.146 against a 0.5 transmit amplitude) but the waveform was gone.
    A short windowed tone is close to the best-case input for Vorbis, so
    the marker survives the codec intact. Emitters are separated by
    frequency rather than by code.

    DETECTOR
    --------
    The signal is decimated by D (boxcar, applied identically to signal
    and template), complex-demodulated against the emitter's frequency
    and correlated with a Hann window. Because

        |sum_j win[j]*s[k+j]*exp(-i*2*pi*f*j)| == |c[k]|

    the demodulation can be folded into the template, so the inner loop
    is a plain complex dot product with no per-sample oscillator. The
    score is a normalised cross-correlation magnitude,

        rho[k] = |c[k]| / sqrt( sum(win^2) * sum(s_window^2) )

    which is 1.0 for a perfect match at any amplitude, and near 0 for
    anything that is not that tone.

    The decimation grid is anchored to an absolute sample index (the
    listener's session origin), not to the chunking, so it is stable
    across calls and independent of how the caller slices the stream.
*/

#ifndef _NINJAM_INTERVAL_PROBE_H_
#define _NINJAM_INTERVAL_PROBE_H_

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <string>
#include <vector>

#define LAB_SRATE 48000

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Emitter i uses this frequency. 400..2500 Hz keeps every marker well
// under the 3 kHz Nyquist of the 6 kHz decimated rate.
static inline int lab_mark_freq(int i)
{
  return 400 + 300*i;
}

// Write a Hann-windowed tone burst of n samples into dst.
static inline void lab_make_tone(float *dst, int n, int srate, int freq, double amp)
{
  for (int x=0; x < n; x ++)
  {
    const double w=0.5 - 0.5*cos(2.0*M_PI*x/(double)(n>1 ? n-1 : 1));
    dst[x]=(float)(amp*w*sin(2.0*M_PI*freq*x/(double)srate));
  }
}

// ---------------------------------------------------------------------------
// Detector
// ---------------------------------------------------------------------------

struct Detection
{
  bool   found;
  double center_sample;   // absolute output sample index of the burst centre
  double peak;            // normalised correlation, 1.0 == perfect match
  double far_peak;        // strongest correlation at least 4 codes away
  int    idx_sample;      // unused, kept for symmetry
};

struct Detector
{
  int   D;         // decimation factor
  int   f_hz;      // marker frequency
  int   Nds;       // template length at the decimated rate
  int   burst;     // burst length at full rate
  float thresh;

  std::vector<float> tr, ti;   // complex template, Nds taps
  double win_energy;
  std::vector<float> hist;     // last Nds-1 decimated samples carried over
  std::vector<float> zbuf;     // scratch: zero pad ++ hist ++ this chunk

  double   dacc;               // running boxcar accumulator
  long long gorigin;           // decimation grid anchor
  long long last_center;       // last accepted detection, to reject duplicates
  bool      have_last;

  Detector() : D(0), f_hz(0), Nds(0), burst(0), thresh(0.50f),
               win_energy(0.0), dacc(0.0), gorigin(0),
               last_center(0), have_last(false) {}

  void init(int decim, int srate, int freq, int burst_samples, float threshold)
  {
    D=decim;
    f_hz=freq;
    burst=burst_samples;
    Nds=burst/D;
    thresh=threshold;
    if (Nds < 2) Nds=2;

    tr.resize(Nds);
    ti.resize(Nds);
    win_energy=0.0;
    const double fd=(double)freq/(double)srate*(double)D; // cycles per decimated sample
    // The template is complex (exp(-i*theta)) but the input signal is real,
    // so a windowed real cosine puts half its energy in each quadrature and
    // a perfect match would score 1/sqrt(2). Scaling the template by sqrt(2)
    // makes a perfect match score exactly 1.0.
    const double norm=sqrt(2.0);
    for (int j=0; j < Nds; j ++)
    {
      const double w=0.5 - 0.5*cos(2.0*M_PI*j/(double)(Nds>1 ? Nds-1 : 1));
      const double ph=2.0*M_PI*fd*j;
      tr[j]=(float)( norm*w*cos(ph));
      ti[j]=(float)(-norm*w*sin(ph));
      win_energy+=w*w;
    }

    hist.assign(Nds-1, 0.0f);
    dacc=0.0;
    have_last=false;
  }

  // Anchor the decimation grid to an absolute sample index. A marker
  // emitted at session position k*mark_period sits at session sample
  // k*mark_period*SRATE; anchoring the grid at the listener's session
  // origin and keeping mark_period*SRATE a multiple of D puts every
  // marker exactly on a grid boundary.
  void set_grid_origin(long long origin)
  {
    gorigin=origin;
    dacc=0.0;
  }

  // Runs the filter over n new samples whose first element is absolute
  // output sample index base. Appends every accepted detection to out.
  int process(const float *in, int n, long long base, std::vector<Detection> &out)
  {
    if (Nds < 2) return 0;

    // [ Nds-1 zeros | hist | new ]. The zero pad keeps every window index
    // non-negative while still scanning the windows that straddle the
    // chunk boundary exactly once.
    const int pad=Nds-1;

    const int r=(int)((((base-gorigin) % D) + D) % D);
    int dcount=(D-1-r+D) % D;

    zbuf.clear();
    zbuf.assign(pad, 0.0f);
    zbuf.insert(zbuf.end(), hist.begin(), hist.end());
    zbuf.reserve((size_t)(2*pad + n/D + 2));

    for (int x=0; x < n; x ++)
    {
      dacc += in[x];
      if (--dcount < 0)
      {
        zbuf.push_back((float)(dacc/(double)D));
        dacc=0.0;
        dcount=D-1;
      }
    }

    const int zstart=2*pad;
    const int zend=(int)zbuf.size();
    const int ncorr=zend-Nds+1;

    if (ncorr >= 1 && win_energy > 0.0)
    {
      std::vector<double> pre2((size_t)zend+1, 0.0);
      for (int q=0; q < zend; q ++)
        pre2[q+1]=pre2[q]+(double)zbuf[q]*zbuf[q];

      std::vector<float> rho(ncorr, 0.0f);
      for (int k=0; k < ncorr; k ++)
      {
        const float *w=&zbuf[k];
        double re=0.0, im=0.0, en=0.0;
        for (int j=0; j < Nds; j ++)
        {
          const double s=w[j];
          re+=s*tr[j];
          im+=s*ti[j];
          en+=s*s;
        }
        if (en <= 1e-12) continue;
        double v=sqrt(re*re+im*im)/sqrt(win_energy*en);
        if (v > 1.0) v=1.0;
        rho[k]=(float)v;
      }

      // local maxima, then keep only the dominant one per burst: a single
      // burst produces a peak plus a skirt of smaller maxima that must not
      // be counted as separate markers
      std::vector<int> peaks;
      for (int k=1; k < ncorr-1; k ++)
      {
        if (rho[k] < 0.5f*rho[k-1] && rho[k] < 0.5f*rho[k+1]) continue;
        if (rho[k] > rho[k-1] && rho[k] >= rho[k+1]) peaks.push_back(k);
      }
      if (!peaks.empty())
      {
        std::vector<int> by_strength(peaks);
        std::sort(by_strength.begin(),by_strength.end(),
                  [&](int a,int b) { return rho[a]>rho[b]; });
        std::vector<int> kept;
        for (size_t a=0; a < by_strength.size(); a ++)
        {
          const int k=by_strength[a];
          bool near=false;
          for (size_t b=0; b < kept.size(); b ++)
            if (abs(k-kept[b]) < Nds) { near=true; break; }
          if (!near) kept.push_back(k);
        }
        std::sort(kept.begin(),kept.end());
        peaks.swap(kept);
      }

      for (size_t p=0; p < peaks.size(); p ++)
      {
        const int k=peaks[p];
        if (rho[k] < thresh) continue;

        // the burst's first decimated sample is zbuf[k], i.e. new index
        // k-zstart; the centre of a symmetric window is half a burst on
        double fr=0.0;
        if (k > 0 && k < ncorr-1)
        {
          const double a=rho[k-1], b=rho[k], c=rho[k+1];
          const double den=(a-2.0*b+c);
          if (den != 0.0)
          {
            fr=0.5*(a-c)/den;
            if (fr > 0.5) fr=0.5;
            if (fr < -0.5) fr=-0.5;
          }
        }
        const double first_new=(double)(k-zstart)+fr;
        const double centre=(double)base + first_new*(double)D + (double)(burst-1)*0.5;

        // A burst is longer than a typical chunk, so the per-chunk peak
        // filter cannot see that several chunks are looking at the same
        // burst. Reject anything within a few burst lengths of the last
        // accepted detection; real markers are mark_period*SRATE samples
        // apart, which is orders of magnitude further.
        //
        // The window has to be comfortably wider than the burst. A Hann
        // template aligned half a burst late still correlates about 0.5
        // with the burst, so the tail of every marker throws a shadow
        // roughly one burst length plus a correlation cell behind the
        // true hit. At a 0.5 threshold that shadow crosses on its own and
        // the same marker gets reported twice.
        if (have_last && fabs(centre-(double)last_center) < 4.0*(double)burst)
          continue;

        double far=0.0;
        for (int q=0; q < ncorr; q ++)
          if (abs(q-k) >= 4*Nds && rho[q] > far) far=rho[q];

        last_center=(long long)llround(centre);
        have_last=true;

        Detection d;
        d.found=true;
        d.center_sample=centre;
        d.peak=rho[k];
        d.far_peak=far;
        d.idx_sample=-1;
        out.push_back(d);
      }
    }

    // carry the last Nds-1 real decimated samples into the next call
    int from=zend-pad;
    if (from < 0) from=0;
    hist.assign(pad, 0.0f);
    for (int j=0, idx=from; idx < zend && j < pad; idx ++, j ++)
      hist[j]=zbuf[idx];

    return (int)out.size();
  }
};

// ---------------------------------------------------------------------------
// options
// ---------------------------------------------------------------------------

struct LabConfig
{
  std::string srvpath;
  std::string outdir;
  std::string tag;

  int    nclients;
  double duration;       // seconds of wall time to measure
  double mark_period;    // seconds of session time between markers
  int    mark_len;       // marker burst length, samples
  int    mark_decim;     // detector decimation
  int    bpi, bpm;
  int    bitrate;
  double amplitude;      // marker transmit amplitude
  double threshold;      // detector acceptance, 0..1

  double late_join_at;   // wall seconds; <0 disables

  // per-client uplink profile: audio loss %, delay ms, jitter ms
  double up_loss, up_delay, up_jitter;
  // server downlink profile (passed to the server process via NJCOND_*)
  double down_loss, down_delay, down_jitter;

  std::vector<double> ppm; // per-client clock offset in ppm

  LabConfig()
    : nclients(3), duration(60.0), mark_period(12.0), mark_len(1920),
      mark_decim(8), bpi(8), bpm(120), bitrate(128), amplitude(0.5),
      threshold(0.50), late_join_at(-1.0),
      up_loss(0.0), up_delay(0.0), up_jitter(0.0),
      down_loss(0.0), down_delay(0.0), down_jitter(0.0)
  {
  }

  bool parse(int argc, char **argv)
  {
    for (int x=1; x < argc; x ++)
    {
      std::string a=argv[x];
      if (a.compare(0,2,"--")==0) a=a.substr(2);

      std::string key=a, val;
      size_t eq=a.find('=');
      if (eq != std::string::npos) { key=a.substr(0,eq); val=a.substr(eq+1); }

      if (key=="srv") srvpath=val;
      else if (key=="out") outdir=val;
      else if (key=="tag") tag=val;
      else if (key=="clients") nclients=atoi(val.c_str());
      else if (key=="duration") duration=atof(val.c_str());
      else if (key=="mark-period") mark_period=atof(val.c_str());
      else if (key=="mark-len") mark_len=atoi(val.c_str());
      else if (key=="decim") mark_decim=atoi(val.c_str());
      else if (key=="bpi") bpi=atoi(val.c_str());
      else if (key=="bpm") bpm=atoi(val.c_str());
      else if (key=="bitrate") bitrate=atoi(val.c_str());
      else if (key=="amplitude") amplitude=atof(val.c_str());
      else if (key=="threshold") threshold=atof(val.c_str());
      else if (key=="late-join") late_join_at=atof(val.c_str());
      else if (key=="ppm")
      {
        // colon-separated, one per client; missing entries are 0
        ppm.clear();
        const char *p=val.c_str();
        while (*p)
        {
          ppm.push_back(atof(p));
          const char *c=strchr(p,':');
          if (!c) break;
          p=c+1;
        }
      }
      else if (key=="up-loss") up_loss=atof(val.c_str());
      else if (key=="up-delay") up_delay=atof(val.c_str());
      else if (key=="up-jitter") up_jitter=atof(val.c_str());
      else if (key=="down-loss") down_loss=atof(val.c_str());
      else if (key=="down-delay") down_delay=atof(val.c_str());
      else if (key=="down-jitter") down_jitter=atof(val.c_str());
      else
      {
        fprintf(stderr,"unknown option: %s\n",a.c_str());
        return false;
      }
    }

    if (srvpath.empty() || outdir.empty() || tag.empty())
    {
      fprintf(stderr,"--srv, --out and --tag are required\n");
      return false;
    }
    if (nclients < 1) nclients=1;
    if (nclients > 8) nclients=8;
    while ((int)ppm.size() < nclients) ppm.push_back(0.0);
    ppm.resize(nclients);

    if (mark_len % mark_decim) mark_len -= mark_len % mark_decim;
    return true;
  }
};

#endif//_NINJAM_INTERVAL_PROBE_H_
