/*
    ninjam/tests/ui_snapshot.cpp

    Offscreen visual-regression harness for the NINJAM GUI client UI.

    It renders the shared UI layer (ninjam/imguiclient/ui.cpp) through Dear
    ImGui with NO window and NO graphics backend: the frame's draw data is
    rasterized by a small software rasterizer into an RGBA buffer and written
    as a PNG. Rendering is fully deterministic (fixed frame times, no input
    events), so the PNGs can be compared against golden snapshots to catch
    UI regressions.

    usage:
      ninjam_ui_snapshot [--update] [empty|mixer|chat ...]

      - always writes <outdir>/<scenario>.png (build/ui-snapshots/)
      - compares against <goldendir>/<scenario>.png (ninjam/tests/golden/)
        when a golden exists, failing on significant pixel differences
      - --update writes/refreshes the golden snapshots instead

    Registered in CTest as ui_snapshot_empty / ui_snapshot_mixer /
    ui_snapshot_chat.
*/

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <direct.h>
#endif

#include <string>
#include <vector>

#include "imgui.h"
#include "ninjam/njclient.h"
#include "ui.h"

#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations" // stb uses sprintf
#endif
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
#endif

#ifndef NINJAM_UI_GOLDEN_DIR
#define NINJAM_UI_GOLDEN_DIR "golden"
#endif
#ifndef NINJAM_UI_OUTDIR
#define NINJAM_UI_OUTDIR "ui-snapshots"
#endif

#define SNAP_W 1360
#define SNAP_H 880

// ---------------------------------------------------------------------------
// software rasterizer for ImDrawData (headless, deterministic)
// ---------------------------------------------------------------------------

struct Framebuf
{
  int w,h;
  std::vector<unsigned char> px;  // RGBA
  const unsigned char *tex;       // font atlas, RGBA
  int tw,th;
};

static int iclamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

static void fb_init(Framebuf *fb, int w, int h, const unsigned char *tex, int tw, int th)
{
  fb->w=w;
  fb->h=h;
  fb->px.assign((size_t)w*h*4,0);
  fb->tex=tex;
  fb->tw=tw;
  fb->th=th;
}

static void fb_clear(Framebuf *fb, unsigned char r, unsigned char g, unsigned char b, unsigned char a)
{
  for (size_t i = 0; i < fb->px.size(); i += 4)
  {
    fb->px[i]=r;
    fb->px[i+1]=g;
    fb->px[i+2]=b;
    fb->px[i+3]=a;
  }
}

// bilinear texture sample; returns straight-alpha RGBA in 0..1
static void tex_sample(const Framebuf *fb, float u, float v, float out[4])
{
  if (!(u >= 0.0f)) u=0.0f; else if (u > 1.0f) u=1.0f;
  if (!(v >= 0.0f)) v=0.0f; else if (v > 1.0f) v=1.0f;
  float x=u*(float)fb->tw-0.5f, y=v*(float)fb->th-0.5f;
  int x0=(int)floorf(x), y0=(int)floorf(y);
  float fx=x-(float)x0, fy=y-(float)y0;
  int xa=iclamp(x0,0,fb->tw-1), xb=iclamp(x0+1,0,fb->tw-1);
  int ya=iclamp(y0,0,fb->th-1), yb=iclamp(y0+1,0,fb->th-1);
  for (int c = 0; c < 4; c ++)
  {
    float s00=(float)fb->tex[((size_t)ya*fb->tw+xa)*4+c];
    float s10=(float)fb->tex[((size_t)ya*fb->tw+xb)*4+c];
    float s01=(float)fb->tex[((size_t)yb*fb->tw+xa)*4+c];
    float s11=(float)fb->tex[((size_t)yb*fb->tw+xb)*4+c];
    float top=s00+(s10-s00)*fx;
    float bot=s01+(s11-s01)*fx;
    out[c]=(top+(bot-top)*fy)*(1.0f/255.0f);
  }
}

static void unpack_col(ImU32 col, float out[4])
{
  out[0]=(float)((col>>IM_COL32_R_SHIFT)&255)*(1.0f/255.0f);
  out[1]=(float)((col>>IM_COL32_G_SHIFT)&255)*(1.0f/255.0f);
  out[2]=(float)((col>>IM_COL32_B_SHIFT)&255)*(1.0f/255.0f);
  out[3]=(float)((col>>IM_COL32_A_SHIFT)&255)*(1.0f/255.0f);
}

// rasterize one triangle into the clipped region (top-left rule approximated
// by nudging sample points off exact grid lines: shared edges can never be
// hit exactly, so no seams and no double blending)
static void fb_triangle(Framebuf *fb, ImDrawVert v0, ImDrawVert v1, ImDrawVert v2,
                        int cx0, int cy0, int cx1, int cy1)
{
  double area=((double)v1.pos.x-v0.pos.x)*((double)v2.pos.y-v0.pos.y)
            - ((double)v1.pos.y-v0.pos.y)*((double)v2.pos.x-v0.pos.x);
  if (area == 0.0) return;
  if (area < 0.0) { ImDrawVert t=v1; v1=v2; v2=t; area=-area; }

  double minx=v0.pos.x < v1.pos.x ? (v0.pos.x < v2.pos.x ? v0.pos.x : v2.pos.x) : (v1.pos.x < v2.pos.x ? v1.pos.x : v2.pos.x);
  double maxx=v0.pos.x > v1.pos.x ? (v0.pos.x > v2.pos.x ? v0.pos.x : v2.pos.x) : (v1.pos.x > v2.pos.x ? v1.pos.x : v2.pos.x);
  double miny=v0.pos.y < v1.pos.y ? (v0.pos.y < v2.pos.y ? v0.pos.y : v2.pos.y) : (v1.pos.y < v2.pos.y ? v1.pos.y : v2.pos.y);
  double maxy=v0.pos.y > v1.pos.y ? (v0.pos.y > v2.pos.y ? v0.pos.y : v2.pos.y) : (v1.pos.y > v2.pos.y ? v1.pos.y : v2.pos.y);

  int x0=iclamp((int)floor(minx),cx0,cx1-1);
  int x1=iclamp((int)ceil(maxx),cx0,cx1-1);
  int y0=iclamp((int)floor(miny),cy0,cy1-1);
  int y1=iclamp((int)ceil(maxy),cy0,cy1-1);
  if (x1 < x0 || y1 < y0) return;

  float c0[4],c1[4],c2[4];
  unpack_col(v0.col,c0);
  unpack_col(v1.col,c1);
  unpack_col(v2.col,c2);

  const double pxoff=0.5+1e-3, pyoff=0.5+1.1e-3;
  const double inv=1.0/area;

  for (int y = y0; y <= y1; y ++)
  {
    unsigned char *dst=&fb->px[((size_t)y*fb->w+x0)*4];
    for (int x = x0; x <= x1; x ++, dst+=4)
    {
      double px=x+pxoff, py=y+pyoff;

      // barycentric edge functions: wN = 2*signed area of the triangle formed
      // by the point and the edge opposite vertex N
      double w0=((double)v2.pos.x-v1.pos.x)*(py-(double)v1.pos.y)-((double)v2.pos.y-v1.pos.y)*(px-(double)v1.pos.x);
      double w1=((double)v0.pos.x-v2.pos.x)*(py-(double)v2.pos.y)-((double)v0.pos.y-v2.pos.y)*(px-(double)v2.pos.x);
      double w2=area-w0-w1;
      if (w0 < 0.0 || w1 < 0.0 || w2 < 0.0) continue;

      double b0=w0*inv, b1=w1*inv, b2=w2*inv;

      float u=(float)(b0*v0.uv.x+b1*v1.uv.x+b2*v2.uv.x);
      float vv=(float)(b0*v0.uv.y+b1*v1.uv.y+b2*v2.uv.y);
      float t[4];
      tex_sample(fb,u,vv,t);

      float vr=(float)(b0*c0[0]+b1*c1[0]+b2*c2[0]);
      float vg=(float)(b0*c0[1]+b1*c1[1]+b2*c2[1]);
      float vb=(float)(b0*c0[2]+b1*c1[2]+b2*c2[2]);
      float va=(float)(b0*c0[3]+b1*c1[3]+b2*c2[3]);

      float sa=t[3]*va;
      float ia=1.0f-sa;
      float sr=t[0]*vr*sa, sg=t[1]*vg*sa, sb=t[2]*vb*sa;

      int r=(int)(sr*255.0f+(float)dst[0]*ia+0.5f);
      int g=(int)(sg*255.0f+(float)dst[1]*ia+0.5f);
      int b=(int)(sb*255.0f+(float)dst[2]*ia+0.5f);
      int a=(int)(sa*255.0f+(float)dst[3]*ia+0.5f);
      dst[0]=(unsigned char)iclamp(r,0,255);
      dst[1]=(unsigned char)iclamp(g,0,255);
      dst[2]=(unsigned char)iclamp(b,0,255);
      dst[3]=(unsigned char)iclamp(a,0,255);
    }
  }
}

static void fb_draw(Framebuf *fb, ImDrawData *dd)
{
  for (int n = 0; n < dd->CmdLists.Size; n ++) // note: CmdListsCount is obsolete in ImGui 1.92
  {
    const ImDrawList *dl=dd->CmdLists[n];
    const ImDrawVert *vtx=dl->VtxBuffer.Data;
    const ImDrawIdx *idx=dl->IdxBuffer.Data;
    for (int c = 0; c < dl->CmdBuffer.Size; c ++)
    {
      const ImDrawCmd *cmd=&dl->CmdBuffer[c];
      if (cmd->UserCallback) continue; // not used by this UI

      int cx0=iclamp((int)floorf(cmd->ClipRect.x),0,fb->w);
      int cy0=iclamp((int)floorf(cmd->ClipRect.y),0,fb->h);
      int cx1=iclamp((int)ceilf(cmd->ClipRect.z),0,fb->w);
      int cy1=iclamp((int)ceilf(cmd->ClipRect.w),0,fb->h);
      if (cx1 <= cx0 || cy1 <= cy0) continue;

      for (unsigned int e = 0; e+2 < cmd->ElemCount; e += 3)
      {
        const ImDrawVert &v0=vtx[cmd->VtxOffset+idx[cmd->IdxOffset+e+0]];
        const ImDrawVert &v1=vtx[cmd->VtxOffset+idx[cmd->IdxOffset+e+1]];
        const ImDrawVert &v2=vtx[cmd->VtxOffset+idx[cmd->IdxOffset+e+2]];
        fb_triangle(fb,v0,v1,v2,cx0,cy0,cx1,cy1);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// snapshot writing / golden comparison
// ---------------------------------------------------------------------------

static bool ensure_dir(const char *path)
{
#ifdef _WIN32
  if (_mkdir(path) == 0) return true;
#else
  if (mkdir(path,0755) == 0) return true;
#endif
  return errno == EEXIST;
}

// per-channel tolerance for anti-aliasing / cross-platform rounding noise
#define SNAP_TOL 12
// allow up to ~0.33% of pixels to exceed the tolerance
#define SNAP_FAIL_FRACTION 300

static int snapshot_check(const char *name, Framebuf &fb, bool update, const char *goldendir, const char *outdir)
{
  char path[1024], gpath[1024];
  snprintf(path,sizeof(path),"%s/%s.png",outdir,name);
  snprintf(gpath,sizeof(gpath),"%s/%s.png",goldendir,name);

  if (!stbi_write_png(path,fb.w,fb.h,4,fb.px.data(),fb.w*4))
  {
    fprintf(stderr,"[ui_snapshot] %s: failed to write %s\n",name,path);
    return 1;
  }

  if (update)
  {
    if (!stbi_write_png(gpath,fb.w,fb.h,4,fb.px.data(),fb.w*4))
    {
      fprintf(stderr,"[ui_snapshot] %s: failed to write golden %s\n",name,gpath);
      return 1;
    }
    printf("[ui_snapshot] %s: golden updated (%s)\n",name,gpath);
    return 0;
  }

  int gw=0,gh=0,gcomp=0;
  unsigned char *gold=stbi_load(gpath,&gw,&gh,&gcomp,4);
  if (!gold)
  {
    printf("[ui_snapshot] %s: no golden snapshot yet (%s); wrote %s (run --update to baseline)\n",name,gpath,path);
    return 0;
  }

  if (gw != fb.w || gh != fb.h)
  {
    fprintf(stderr,"[ui_snapshot] %s: FAIL - size mismatch: golden %dx%d, actual %dx%d\n",name,gw,gh,fb.w,fb.h);
    stbi_image_free(gold);
    return 1;
  }

  std::vector<unsigned char> diff((size_t)fb.w*fb.h*4);
  size_t bad=0;
  size_t total=(size_t)fb.w*fb.h;
  for (size_t i = 0; i < total; i ++)
  {
    const unsigned char *a=&fb.px[i*4];
    const unsigned char *g=&gold[i*4];
    bool d=false;
    for (int c = 0; c < 4; c ++)
    {
      int delta=a[c] > g[c] ? a[c]-g[c] : g[c]-a[c];
      if (delta > SNAP_TOL) { d=true; break; }
    }
    if (d)
    {
      bad++;
      diff[i*4]=255; diff[i*4+1]=64; diff[i*4+2]=64; diff[i*4+3]=255;
    }
    else
    {
      // dimmed actual for context in the diff image
      diff[i*4]  =(unsigned char)(a[0]/3+g[0]/6);
      diff[i*4+1]=(unsigned char)(a[1]/3+g[1]/6);
      diff[i*4+2]=(unsigned char)(a[2]/3+g[2]/6);
      diff[i*4+3]=255;
    }
  }
  stbi_image_free(gold);

  size_t allowed=total/SNAP_FAIL_FRACTION;
  if (bad > allowed)
  {
    char dpath[1024];
    snprintf(dpath,sizeof(dpath),"%s/%s.diff.png",outdir,name);
    stbi_write_png(dpath,fb.w,fb.h,4,diff.data(),fb.w*4);
    fprintf(stderr,"[ui_snapshot] %s: FAIL - %zu pixels differ from golden (allowed %zu)\n",name,bad,allowed);
    fprintf(stderr,"[ui_snapshot]   actual: %s\n[ui_snapshot]   diff:   %s\n",path,dpath);
    return 1;
  }
  printf("[ui_snapshot] %s: ok (%zu pixels beyond tolerance, within budget)\n",name,bad);
  return 0;
}

// ---------------------------------------------------------------------------
// scenarios (fixed state, no wall clock, no input)
// ---------------------------------------------------------------------------

static void scenario_empty()
{
  ui_set_audio_status(true,false,48000,2,2,"");
  ui_set_workdir("ninjam-audio");
  ui_set_connect_fields("","","");
}

static void scenario_mixer()
{
  ui_set_audio_status(false,true,48000,2,2,"");
  ui_set_workdir("ninjam-audio");

  NJClient *c=ui_client();
  c->SetWorkDir("ninjam-audio");
  c->SetLocalChannelInfo(0,"guitar",true,0,true,64,true,true);
  c->SetLocalChannelMonitoring(0,true,0.85f,true,-0.30f,false,false,false,false);
  c->SetLocalChannelInfo(1,"keys",true,1,true,128,false,false);
  c->SetLocalChannelMonitoring(1,true,1.20f,true,0.60f,true,false,false,false);
  c->config_mastervolume=0.90f;
  c->config_masterpan=0.10f;
  c->config_metronome=0.50f;
  c->config_metronome_mute=true;

  // pump a fixed synthetic signal through the client so the meters register
  // (deterministic: same samples every run, no files are written)
  float l[512],r[512],ol[512],orr[512];
  float *ins[2]={l,r};
  float *outs[2]={ol,orr};
  for (int i = 0; i < 512; i ++) { l[i]=0.4f; r[i]=0.2f; }
  for (int k = 0; k < 4; k ++) c->AudioProc(ins,2,outs,2,512,48000);

  c->config_savelocalaudio=1; // shown in the recording combo (set after audio)
}

static void scenario_chat()
{
  ui_set_audio_status(false,true,48000,2,2,"");
  ui_set_workdir("ninjam-audio");

  const char *m1[]={"JOIN","carol"};               ui_chat_message(m1,2);
  const char *m2[]={"MSG","alice","hey, nice turnaround on the bridge"}; ui_chat_message(m2,3);
  const char *m3[]={"MSG","bob","thanks! trying a new tone today"};      ui_chat_message(m3,3);
  const char *m4[]={"PRIVMSG","bob","want to trade solos at the next interval?"}; ui_chat_message(m4,3);
  const char *m5[]={"TOPIC","alice","Sunday evening jam - be excellent to each other"};
  ui_chat_message(m5,3);
  const char *m6[]={"MSG","carol","this is a deliberately long chat line to verify that long messages wrap nicely inside the narrow chat column of the application shell"};
  ui_chat_message(m6,3);
}

// ---------------------------------------------------------------------------
// runner
// ---------------------------------------------------------------------------

struct Scenario { const char *name; void (*setup)(); };

static int run_scenario(const Scenario &sc, bool update, const char *goldendir, const char *outdir)
{
  IMGUI_CHECKVERSION();
  ImGui::CreateContext();
  ImGuiIO &io=ImGui::GetIO();
  io.IniFilename=NULL;
  ui_setup_context();
  io.DisplaySize=ImVec2(SNAP_W,SNAP_H);

  // build the font atlas before the first frame; keep its pixels to rasterize
  unsigned char *texpixels=NULL;
  int tw=0,th=0;
  io.Fonts->GetTexDataAsRGBA32(&texpixels,&tw,&th);

  ui_reset();

  // settle client-side peak meters: output_peaklevel only decays per audio
  // block, so pump silence until it falls below the meter floor. This makes
  // meter rendering independent of what previous scenarios processed.
  {
    float z0[512]={0},z1[512]={0},o0[512],o1[512];
    float *ins[2]={z0,z1}, *outs[2]={o0,o1};
    NJClient *c=ui_client();
    for (int i = 0; i < 4000 && (c->GetOutputPeak(0) > 1.0e-5 || c->GetOutputPeak(1) > 1.0e-5); i ++)
      c->AudioProc(ins,2,outs,2,512,48000);
  }

  sc.setup();

  // a few frames so meters and peak-hold state settle deterministically
  for (int f = 0; f < 3; f ++)
  {
    io.DeltaTime=1.0f/60.0f;
    ImGui::NewFrame();
    ui_draw();
    ImGui::Render();
  }

  Framebuf fb;
  fb_init(&fb,SNAP_W,SNAP_H,texpixels,tw,th);
  fb_clear(&fb,26,26,31,255); // the same color the app clears to
  fb_draw(&fb,ImGui::GetDrawData());

  int rc=snapshot_check(sc.name,fb,update,goldendir,outdir);
  ImGui::DestroyContext();
  return rc;
}

int main(int argc, char **argv)
{
  const Scenario scenarios[]={
    { "empty", scenario_empty },
    { "mixer", scenario_mixer },
    { "chat",  scenario_chat  },
  };
  const int nscenarios=(int)(sizeof(scenarios)/sizeof(scenarios[0]));

  bool update=false;
  std::vector<const char*> want;
  for (int i = 1; i < argc; i ++)
  {
    if (!strcmp(argv[i],"--update")) update=true;
    else if (!strcmp(argv[i],"--help"))
    {
      printf("ninjam_ui_snapshot [--update] [empty|mixer|chat ...]\n");
      return 0;
    }
    else want.push_back(argv[i]);
  }

  const char *goldendir=NINJAM_UI_GOLDEN_DIR;
  const char *outdir=NINJAM_UI_OUTDIR;
  if (!ensure_dir(outdir)) fprintf(stderr,"[ui_snapshot] warning: could not create %s\n",outdir);
  if (update && !ensure_dir(goldendir)) fprintf(stderr,"[ui_snapshot] warning: could not create %s\n",goldendir);

  int fail=0;
  for (int s = 0; s < nscenarios; s ++)
  {
    bool run=want.empty();
    for (size_t k = 0; k < want.size(); k ++)
      if (!strcmp(want[k],scenarios[s].name)) run=true;
    if (run) fail|=run_scenario(scenarios[s],update,goldendir,outdir);
  }

  for (size_t k = 0; k < want.size(); k ++)
  {
    bool known=false;
    for (int s = 0; s < nscenarios; s ++)
      if (!strcmp(want[k],scenarios[s].name)) known=true;
    if (!known)
    {
      fprintf(stderr,"[ui_snapshot] unknown scenario: %s\n",want[k]);
      fail=1;
    }
  }
  return fail;
}
