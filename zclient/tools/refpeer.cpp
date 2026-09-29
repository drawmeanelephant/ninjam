/*
    zclient/tools/refpeer.cpp

    Interop harness: drives the REFERENCE NINJAM client core (NJClient from
    ninjam/njclient.cpp) headlessly, exactly like ninjam/tests/e2e_test.cpp
    does. It joins a live ninjamsrv session, broadcasts a local tone, and
    measures the audio it decodes from its remote peers.

    Purpose: prove two-way audio interop between zclient (Zig) and the
    unmodified reference client:
      - refpeer receives zclient's uploaded Vorbis intervals and decodes them
        through the reference client's own libvorbis path (rx energy + peak).
      - zclient receives refpeer's tone and dumps it to WAV (verified there).

    Build (from repo root):
      clang++ -std=c++17 -O2 zclient/tools/refpeer.cpp \
        -I. -Ibuild_deps/... \
        libninjam_core.a libninjam_net.a <ogg/vorbis libs> -o refpeer

    Usage: refpeer --host 127.0.0.1:20491 --user anonymous:refpeer --pass x
                   --duration 25 [--freq 440] [--amp 0.5] [--report FILE]
*/

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <chrono>
#include <string>
#include <thread>
#include <vector>

#include "ninjam/njclient.h"
#include "WDL/jnetlib/util.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define CHUNK 4800
#define SRATE 48000

static float s_in[2][CHUNK], s_out[2][CHUNK];
static float *s_ins[2] = { s_in[0], s_in[1] };
static float *s_outs[2] = { s_out[0], s_out[1] };

struct Ctx
{
  std::vector<std::string> chat;
};

static void chat_cb(void *userData, NJClient *, const char **parms, int nparms)
{
  Ctx *ctx = (Ctx *)userData;
  std::string line;
  for (int x = 0; x < nparms; x++)
  {
    if (x) line += " | ";
    if (parms[x]) line += parms[x];
  }
  ctx->chat.push_back(line);
}

static int license_cb(void *, const char *) { return 1; } // auto-accept

static void feed_audio(NJClient &cl, double *phase, double freq, double amp)
{
  for (int x = 0; x < CHUNK; x++)
  {
    double v = phase ? amp * sin(*phase) : 0.0;
    if (phase)
    {
      *phase += 2.0 * M_PI * freq / (double)SRATE;
      if (*phase > 2.0 * M_PI) *phase -= 2.0 * M_PI;
    }
    s_in[0][x] = s_in[1][x] = (float)v;
    s_out[0][x] = s_out[1][x] = 0.0f;
  }
  cl.AudioProc(s_ins, 2, s_outs, 2, CHUNK, SRATE);
}

int main(int argc, char **argv)
{
  const char *host = "127.0.0.1:20491";
  const char *user = "anonymous:refpeer";
  const char *pass = "x";
  double duration = 25.0;
  double freq = 440.0, amp = 0.5;
  const char *report = NULL;

  for (int i = 1; i < argc; i++)
  {
    if (!strcmp(argv[i], "--host") && i + 1 < argc) host = argv[++i];
    else if (!strcmp(argv[i], "--user") && i + 1 < argc) user = argv[++i];
    else if (!strcmp(argv[i], "--pass") && i + 1 < argc) pass = argv[++i];
    else if (!strcmp(argv[i], "--duration") && i + 1 < argc) duration = atof(argv[++i]);
    else if (!strcmp(argv[i], "--freq") && i + 1 < argc) freq = atof(argv[++i]);
    else if (!strcmp(argv[i], "--amp") && i + 1 < argc) amp = atof(argv[++i]);
    else if (!strcmp(argv[i], "--report") && i + 1 < argc) report = argv[++i];
  }

  JNL::open_socketlib();

  NJClient client;
  Ctx ctx;
  client.ChatMessage_Callback = chat_cb;
  client.ChatMessage_User = &ctx;
  client.LicenseAgreementCallback = license_cb;
  client.config_savelocalaudio = -1; // keep decoded buffers in memory only
  client.config_play_prebuffer = -1; // play decoded audio immediately
  client.config_metronome = 0.0f;
  client.config_metronome_mute = true;
  client.SetWorkDir(".");

  printf("[refpeer] connecting to %s as %s\n", host, user);
  client.Connect(host, user, pass);

  // wait for auth
  auto t0 = std::chrono::steady_clock::now();
  while (client.GetStatus() != NJClient::NJC_STATUS_OK)
  {
    client.Run();
    if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > 15.0)
    {
      printf("REFPEER RESULT ok=0 reason=auth_timeout\n");
      return 1;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  printf("[refpeer] joined (status OK)\n");

  // broadcast a tone on a local channel so zclient has something to decode
  client.SetLocalChannelInfo(0, "refpeer-tone", true, 0, true, 64, true, true);
  client.NotifyServerOfChannelChange();

  double phase = 0.0, rx_energy = 0.0;
  double remote_peak = 0.0;
  int remote_channels_seen = 0;
  const double run_secs = duration;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(run_secs);
  const double block_wall = (double)CHUNK / (double)SRATE; // real-time pacing

  // pump at real time so NJClient's interval clock matches the server's
  while (std::chrono::steady_clock::now() < deadline)
  {
    const auto block_start = std::chrono::steady_clock::now();

    feed_audio(client, &phase, freq, amp); // we transmit

    // measure decoded remote audio energy in our output mix
    double block_energy = 0.0;
    for (int x = 0; x < CHUNK; x++)
      block_energy += (double)s_out[0][x] * (double)s_out[0][x];
    rx_energy += block_energy;

    int sleepok = client.Run();
    for (int spins = 0; !sleepok && spins < 64; spins++) sleepok = client.Run();

    // subscribe + track remote channels (as ninjam/tests/e2e_test.cpp does)
    for (int u = 0; u < client.GetNumUsers(); u++)
    {
      for (int ch = 0; client.EnumUserChannels(u, ch) >= 0; ch++)
      {
        remote_channels_seen++;
        client.SetUserChannelState(u, ch, true, true, false, 0, false, 0, false, false, false, false);
        float pk = client.GetUserChannelPeak(u, ch);
        if (pk > remote_peak) remote_peak = pk;
      }
    }

    // keep the pump at real time
    const double spent = std::chrono::duration<double>(std::chrono::steady_clock::now() - block_start).count();
    if (spent < block_wall)
      std::this_thread::sleep_for(std::chrono::duration<double>(block_wall - spent));
  }
  client.Disconnect();
  JNL::close_socketlib();

  // A passing run requires: we saw at least one remote channel and the
  // reference client's decoder produced real signal energy from it.
  int ok = (remote_channels_seen > 0) && (remote_peak > 1e-4) && (rx_energy > 1e-4);
  printf("REFPEER RESULT ok=%d remote_channels_seen=%d remote_peak=%.6f rx_energy=%.6f chat_lines=%zu\n",
         ok, remote_channels_seen, remote_peak, rx_energy, ctx.chat.size());
  if (report)
  {
    FILE *fp = fopen(report, "w");
    if (fp)
    {
      fprintf(fp, "REFPEER RESULT ok=%d remote_channels_seen=%d remote_peak=%.6f rx_energy=%.6f chat_lines=%zu\n",
              ok, remote_channels_seen, remote_peak, rx_energy, ctx.chat.size());
      for (auto &l : ctx.chat) fprintf(fp, "chat: %s\n", l.c_str());
      fclose(fp);
    }
  }
  return ok ? 0 : 1;
}
