// Standalone self-test for the interval_lab marker Detector.
// Built as ninjam_probe_selftest; run with no arguments.
//
// The detector is the measuring instrument for the whole experiment, so it
// gets checked against streams where the right answer is known exactly:
// a tone burst at a known sample index, the same burst straddling a chunk
// boundary, silence, white noise, and a different emitter's frequency.

#include "interval_probe.h"

#include <vector>

static double max_peak(const std::vector<Detection> &d)
{
  double m=0.0;
  for (size_t x=0; x < d.size(); x ++) if (d[x].peak>m) m=d[x].peak;
  return m;
}

int main()
{
  const int D=8;
  const int BURST=1920;              // 40 ms at 48 kHz
  const int F_A=lab_mark_freq(0);    // 400 Hz
  const int F_B=lab_mark_freq(1);    // 700 Hz
  int fails=0;

  std::vector<float> tone_a(BURST), tone_b(BURST);
  lab_make_tone(&tone_a[0],BURST,LAB_SRATE,F_A,0.5);
  lab_make_tone(&tone_b[0],BURST,LAB_SRATE,F_B,0.5);

  // --- case 1: one burst at a known offset ---
  {
    Detector det;
    det.init(D,LAB_SRATE,F_A,BURST,0.50f);
    det.set_grid_origin(0);

    const int N=48000;
    std::vector<float> buf(N,0.0f);
    const int at=20000;             // multiple of D, so on the grid
    for (int x=0; x < BURST; x ++) buf[at+x]=tone_a[x];

    std::vector<Detection> dets;
    det.process(&buf[0],N/2,0,dets);
    det.process(&buf[N/2],N-N/2,N/2,dets);

    const double want=at+(BURST-1)/2.0;
    if (dets.size()!=1)
    {
      printf("FAIL case1: expected 1 detection, got %d\n",(int)dets.size());
      fails++;
    }
    else
    {
      const double got=dets[0].center_sample;
      printf("case1: centre %.2f (want %.2f, err %+.2f samples) peak %.4f\n",
        got,want,got-want,dets[0].peak);
      if (fabs(got-want) > 4.0) { printf("FAIL case1: position off by >4 samples\n"); fails++; }
      if (dets[0].peak < 0.99f)  { printf("FAIL case1: peak %.4f < 0.99\n",dets[0].peak); fails++; }
    }
  }

  // --- case 1b: a burst straddling a chunk boundary must still be found ---
  {
    Detector det;
    det.init(D,LAB_SRATE,F_A,BURST,0.50f);
    det.set_grid_origin(0);
    const int N=48000;
    std::vector<float> buf(N,0.0f);
    const int at=24000-800;         // spans the 24000-sample chunk edge
    for (int x=0; x < BURST; x ++) buf[at+x]=tone_a[x];

    std::vector<Detection> dets;
    det.process(&buf[0],N/2,0,dets);
    det.process(&buf[N/2],N-N/2,N/2,dets);

    const double want=at+(BURST-1)/2.0;
    if (dets.size()!=1)
    {
      printf("FAIL case1b: burst across chunk boundary -> %d detections (want 1)\n",(int)dets.size());
      fails++;
    }
    else
    {
      printf("case1b: centre %.2f (want %.2f, err %+.2f) peak %.4f\n",
        dets[0].center_sample,want,dets[0].center_sample-want,dets[0].peak);
      if (fabs(dets[0].center_sample-want) > 4.0) { printf("FAIL case1b: position\n"); fails++; }
      if (dets[0].peak < 0.99f) { printf("FAIL case1b: peak %.4f < 0.99\n",dets[0].peak); fails++; }
    }
  }

  // --- case 2: silence and white noise must not fire ---
  {
    Detector det;
    det.init(D,LAB_SRATE,F_A,BURST,0.50f);
    det.set_grid_origin(0);
    std::vector<float> buf(48000,0.0f);
    std::vector<Detection> dets;
    det.process(&buf[0],48000,0,dets);
    printf("case2 (silence): %d detections\n",(int)dets.size());
    if (dets.size()!=0) { printf("FAIL case2: fired on silence\n"); fails++; }

    unsigned s=12345;
    for (int x=0; x < 48000; x ++)
    {
      s=s*1103515245u+12345u;
      buf[x]=0.1f*(((s>>16)&1)?1.0f:-1.0f);
    }
    dets.clear();
    det.process(&buf[0],48000,0,dets);
    printf("case2 (white noise): %d detections at thresh 0.50, max peak %.4f\n",
      (int)dets.size(),max_peak(dets));
    if (dets.size()!=0) { printf("FAIL case2: fired on white noise\n"); fails++; }
  }

  // --- case 3: a different emitter's frequency must be rejected ---
  {
    Detector det_a, det_b, det_c;
    det_a.init(D,LAB_SRATE,F_A,BURST,0.0f);   // threshold off: raw rejection
    det_b.init(D,LAB_SRATE,F_B,BURST,0.0f);
    det_c.init(D,LAB_SRATE,F_A,BURST,0.50f);  // code A at the operating threshold
    det_a.set_grid_origin(0);
    det_b.set_grid_origin(0);
    det_c.set_grid_origin(0);

    std::vector<float> buf(48000,0.0f);
    const int at=20000;
    for (int x=0; x < BURST; x ++) buf[at+x]=tone_b[x];

    std::vector<Detection> da,db,dc;
    det_a.process(&buf[0],48000,0,da);
    det_b.process(&buf[0],48000,0,db);
    det_c.process(&buf[0],48000,0,dc);

    printf("case3: %d Hz detector sees a %d Hz burst -> %d dets, worst cross-correlation %.4f\n",
      F_A,F_B,(int)da.size(),max_peak(da));
    printf("case3: %d Hz detector sees its own burst  -> %d dets, best peak %.4f\n",
      F_B,(int)db.size(),max_peak(db));
    printf("case3: at thresh 0.50, %d Hz detector sees a %d Hz burst -> %d dets\n",
      F_A,F_B,(int)dc.size());
    if (!dc.empty()) { printf("FAIL case3: cross-frequency detection above threshold\n"); fails++; }
    if (max_peak(db) < 0.99) { printf("FAIL case3: self correlation not ~1.0\n"); fails++; }
  }

  printf(fails ? "SELFTEST FAILED (%d)\n" : "SELFTEST PASSED (%d)\n",fails);
  return fails ? 1 : 0;
}
