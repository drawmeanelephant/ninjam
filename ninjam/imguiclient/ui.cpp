/*
    NINJAM client - ui.cpp

    All UI drawing for the revived NINJAM GUI client. This unit is
    deliberately free of GLFW/OpenGL/backend dependencies so it can also be
    rendered offscreen to PNG snapshots by the visual-regression harness in
    ninjam/tests/ui_snapshot.cpp.

    Layout: a fixed application shell with a top status bar, a left sidebar
    (connection / session / mix), a center mixer area (local channels over
    remote users) and a right-hand chat column, separated by draggable
    splitters.
*/

#include <stdio.h>
#include <string.h>

#include <map>
#include <string>
#include <vector>

#include "ninjam/njclient.h"
#include "ninjam/njmisc.h"
#include "auto_reconnect.h"

#include "imgui.h"
#include "imgui_stdlib.h"

#include "ui.h"

// ---------------------------------------------------------------------------
// globals
// ---------------------------------------------------------------------------

static NJClient g_client;

static int g_srate=48000;
static int g_innch=2, g_outnch=2;
static bool g_noaudio=false;
static bool g_audiorunning=false;
static char g_audioerr[256]="";
static std::string g_workdir="ninjam-audio";

static char g_hostbuf[256]="";
static char g_userbuf[128]="";
static char g_passbuf[128]="";
static AutoReconnect g_auto_reconnect;

static std::vector<std::string> g_chatlines;
static bool g_chatscroll=true;
static char g_chatinput[512]="";

struct LocalChanUI
{
  std::string name;
  int srcch, bitrate;
};

static std::map<int, LocalChanUI> g_localui;

// panel proportions (draggable splitters)
static float g_sidebarw=318.0f;
static float g_chatw=372.0f;
static float g_localh=0.0f; // 0 = default fraction, resolved on first frame

// ---------------------------------------------------------------------------
// palette / style
// ---------------------------------------------------------------------------

static const ImVec4 kAccent(0.24f,0.55f,0.95f,1.0f);
static const ImVec4 kGood  (0.22f,0.72f,0.36f,1.0f);
static const ImVec4 kWarn  (0.95f,0.72f,0.20f,1.0f);
static const ImVec4 kBad   (0.92f,0.32f,0.32f,1.0f);
static const ImVec4 kDim   (0.55f,0.56f,0.60f,1.0f);
static const ImVec4 kCardBg(0.145f,0.148f,0.165f,1.0f);

static void apply_style()
{
  ImGuiStyle &style=ImGui::GetStyle();
  style.WindowRounding=6.0f;
  style.ChildRounding=5.0f;
  style.FrameRounding=5.0f;
  style.PopupRounding=5.0f;
  style.ScrollbarRounding=6.0f;
  style.GrabRounding=4.0f;
  style.TabRounding=5.0f;
  style.WindowPadding=ImVec2(12,10);
  style.FramePadding=ImVec2(10,6);
  style.ItemSpacing=ImVec2(9,7);
  style.ItemInnerSpacing=ImVec2(7,5);
  style.ScrollbarSize=15.0f;
  style.GrabMinSize=13.0f;
  style.WindowBorderSize=1.0f;
  style.ChildBorderSize=1.0f;
  style.FrameBorderSize=0.0f;

  ImVec4 *c=style.Colors;
  c[ImGuiCol_Text]=ImVec4(0.92f,0.93f,0.95f,1.00f);
  c[ImGuiCol_TextDisabled]=kDim;
  c[ImGuiCol_WindowBg]=ImVec4(0.095f,0.098f,0.110f,1.00f);
  c[ImGuiCol_ChildBg]=ImVec4(0.115f,0.118f,0.130f,1.00f);
  c[ImGuiCol_PopupBg]=ImVec4(0.115f,0.118f,0.130f,1.00f);
  c[ImGuiCol_Border]=ImVec4(0.22f,0.23f,0.26f,1.00f);
  c[ImGuiCol_BorderShadow]=ImVec4(0,0,0,0);
  c[ImGuiCol_FrameBg]=ImVec4(0.165f,0.170f,0.190f,1.00f);
  c[ImGuiCol_FrameBgHovered]=ImVec4(0.22f,0.24f,0.28f,1.00f);
  c[ImGuiCol_FrameBgActive]=ImVec4(0.26f,0.29f,0.34f,1.00f);
  c[ImGuiCol_Button]=ImVec4(0.22f,0.24f,0.28f,1.00f);
  c[ImGuiCol_ButtonHovered]=ImVec4(0.30f,0.34f,0.42f,1.00f);
  c[ImGuiCol_ButtonActive]=kAccent;
  c[ImGuiCol_Header]=ImVec4(0.22f,0.24f,0.28f,1.00f);
  c[ImGuiCol_HeaderHovered]=ImVec4(0.30f,0.34f,0.42f,1.00f);
  c[ImGuiCol_HeaderActive]=ImVec4(0.32f,0.38f,0.48f,1.00f);
  c[ImGuiCol_Separator]=ImVec4(0.22f,0.23f,0.26f,1.00f);
  c[ImGuiCol_CheckMark]=kAccent;
  c[ImGuiCol_SliderGrab]=ImVec4(0.42f,0.55f,0.80f,1.00f);
  c[ImGuiCol_SliderGrabActive]=kAccent;
  c[ImGuiCol_ScrollbarBg]=ImVec4(0.08f,0.08f,0.09f,0.60f);
  c[ImGuiCol_ScrollbarGrab]=ImVec4(0.28f,0.29f,0.32f,1.00f);
  c[ImGuiCol_ScrollbarGrabHovered]=ImVec4(0.36f,0.38f,0.42f,1.00f);
  c[ImGuiCol_ScrollbarGrabActive]=ImVec4(0.42f,0.44f,0.50f,1.00f);
  c[ImGuiCol_TitleBg]=ImVec4(0.10f,0.10f,0.12f,1.00f);
  c[ImGuiCol_TitleBgActive]=ImVec4(0.13f,0.14f,0.17f,1.00f);
}

// ---------------------------------------------------------------------------
// state management (see ui.h)
// ---------------------------------------------------------------------------

void ui_add_chat_line(const char *line)
{
  if (!line || !*line) return;
  g_chatlines.push_back(line);
  if (g_chatlines.size() > 1000) g_chatlines.erase(g_chatlines.begin(),g_chatlines.begin()+500);
}

void ui_chat_message(const char **parms, int nparms)
{
  if (!parms || nparms < 1 || !parms[0]) return;

  std::string line;
  if (!strcmp(parms[0],"MSG"))
  {
    if (parms[1] && parms[1][0]) { line=parms[1]; line+=": "; }
    if (parms[2]) line+=parms[2];
  }
  else if (!strcmp(parms[0],"PRIVMSG"))
  {
    line="[private from ";
    line+=(parms[1]&&parms[1][0])?parms[1]:"?";
    line+="] ";
    if (parms[2]) line+=parms[2];
  }
  else if (!strcmp(parms[0],"TOPIC"))
  {
    line="*** topic: ";
    if (parms[2] && parms[2][0]) line+=parms[2];
    if (parms[1] && parms[1][0]) { line+=" (set by "; line+=parms[1]; line+=")"; }
  }
  else if (!strcmp(parms[0],"JOIN") || !strcmp(parms[0],"PART"))
  {
    if (parms[1] && parms[1][0])
    {
      line="*** ";
      line+=parms[1];
      line+=(parms[0][0]=='P') ? " left" : " joined";
    }
  }
  else
  {
    for (int x = 0; x < nparms; x ++)
    {
      if (x) line+=" ";
      if (parms[x]) line+=parms[x];
    }
  }
  if (line.empty()) return;
  ui_add_chat_line(line.c_str());
}



// ---------------------------------------------------------------------------
// small UI helpers
// ---------------------------------------------------------------------------

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

struct MeterHold { float hold; double t; };
static std::map<ImGuiID,MeterHold> g_meterholds;

// dB-scaled peak meter (-60dB..+6dB) with gradient fill and peak-hold marker
static void peak_meter(const char *id, float peak, float width=-1.0f, float height=14.0f)
{
  if (width < 0.0f) width=ImGui::GetContentRegionAvail().x;

  MeterHold &hs=g_meterholds[ImGui::GetID(id)];

  double now=ImGui::GetTime();
  if (peak >= hs.hold) { hs.hold=peak; hs.t=now; }
  else if (now-hs.t > 1.5) hs.hold=peak; // hold ~1.5s then follow
  if (hs.hold < peak) hs.hold=peak;

  double db=peak > 1.0e-6 ? VAL2DB(peak) : -60.0;
  float frac=clampf((float)((db+60.0)/66.0),0.0f,1.0f);
  double hdb=hs.hold > 1.0e-6 ? VAL2DB(hs.hold) : -60.0;
  float hfrac=clampf((float)((hdb+60.0)/66.0),0.0f,1.0f);

  // color zones: green below -12dB, yellow to -3dB, red above
  ImVec4 col=kGood;
  if (db > -3.0) col=kBad;
  else if (db > -12.0) col=kWarn;

  ImVec2 p=ImGui::GetCursorScreenPos();
  ImDrawList *dl=ImGui::GetWindowDrawList();
  ImU32 bg=IM_COL32(38,39,44,255), border=IM_COL32(70,72,80,255);

  dl->AddRectFilled(p,ImVec2(p.x+width,p.y+height),bg,3.0f);
  if (frac > 0.002f)
    dl->AddRectFilled(p,ImVec2(p.x+width*frac,p.y+height),ImGui::ColorConvertFloat4ToU32(col),3.0f);

  // tick marks at -24, -12, -6, 0 dB
  const double ticks[4]={ -24.0,-12.0,-6.0,0.0 };
  for (int i = 0; i < 4; i ++)
  {
    float tf=clampf((float)((ticks[i]+60.0)/66.0),0.0f,1.0f);
    float x=p.x+width*tf;
    dl->AddLine(ImVec2(x,p.y+2),ImVec2(x,p.y+height-2),IM_COL32(255,255,255,36),1.0f);
  }

  // peak-hold marker
  if (hfrac > 0.002f)
    dl->AddRectFilled(ImVec2(p.x+width*hfrac-1.5f,p.y),ImVec2(p.x+width*hfrac+1.5f,p.y+height),IM_COL32(235,235,240,220));

  dl->AddRect(p,ImVec2(p.x+width,p.y+height),border,3.0f);
  ImGui::Dummy(ImVec2(width,height));
}

// text truncated with an ellipsis so it can't overlap neighboring columns
static void text_fit(const char *s, float maxw)
{
  if (!s) s="?";
  if (maxw < 20.0f) maxw=20.0f;
  if (ImGui::CalcTextSize(s).x <= maxw)
  {
    ImGui::TextUnformatted(s);
    return;
  }
  float dotw=ImGui::CalcTextSize("...").x;
  size_t len=strlen(s);
  while (len > 0 && ImGui::CalcTextSize(std::string(s,len).c_str()).x > maxw-dotw) len--;
  ImGui::TextUnformatted((std::string(s,len)+"...").c_str());
}

static void dB_text(float vol)
{
  if (vol > 1.0e-6f) ImGui::Text("%+.1f dB",VAL2DB(vol));
  else ImGui::TextDisabled("-inf dB");
}

// vol/pan sliders + dB readout + optional mute/solo; widths adapt to row width.
// returns change flags: 1 = vol/pan changed, 2 = mute changed, 4 = solo changed
static int mixer_row(const char *id, float *vol, float *pan, bool *mute, bool *solo)
{
  int ch=0;
  ImGui::PushID(id);

  float sp=ImGui::GetStyle().ItemSpacing.x;
  float flagw=(mute?28.0f:0.0f)+(solo?28.0f:0.0f);
  float dbw=88.0f;
  float avail=ImGui::GetContentRegionAvail().x-dbw-flagw-3.0f*sp;
  float volw=avail*0.56f, panw=avail*0.44f;
  if (volw < 92.0f) volw=92.0f; // keep "vol 0.00" legible
  if (panw < 92.0f) panw=92.0f;

  ImGui::SetNextItemWidth(volw);
  if (ImGui::SliderFloat("##vol",vol,0.0f,2.0f,"vol %.2f")) ch|=1;
  ImGui::SetItemTooltip("channel volume");
  ImGui::SameLine(0.0f,sp);
  ImGui::SetNextItemWidth(panw);
  if (ImGui::SliderFloat("##pan",pan,-1.0f,1.0f,"pan %.2f")) ch|=1;
  ImGui::SetItemTooltip("pan: -1 hard left, +1 hard right");
  ImGui::SameLine(0.0f,sp);
  dB_text(*vol);
  if (mute)
  {
    ImGui::SameLine(0.0f,sp);
    if (ImGui::Checkbox("##mute",mute)) ch|=2;
    ImGui::SetItemTooltip("mute");
  }
  if (solo)
  {
    ImGui::SameLine(0.0f,sp);
    if (ImGui::Checkbox("##solo",solo)) ch|=4;
    ImGui::SetItemTooltip("solo");
  }
  ImGui::PopID();
  return ch;
}

// draggable vertical splitter; updates *size (width of the panel to its left,
// or to its right when invert is set)
static void vsplitter(const char *id, float *size, float lo, float hi, float height, bool invert=false)
{
  ImGui::PushID(id);
  ImGui::InvisibleButton("##split",ImVec2(6.0f,height));
  bool hovered=ImGui::IsItemHovered();
  bool active=ImGui::IsItemActive();
  if (active) *size=clampf(*size+(invert?-ImGui::GetIO().MouseDelta.x:ImGui::GetIO().MouseDelta.x),lo,hi);
  ImVec2 mn=ImGui::GetItemRectMin(), mx=ImGui::GetItemRectMax();
  ImGui::PopID();
  ImDrawList *dl=ImGui::GetWindowDrawList();
  dl->AddRectFilled(mn,mx,active?IM_COL32(70,120,200,255):hovered?IM_COL32(70,74,86,255):IM_COL32(0,0,0,0),1.0f);
}

// draggable horizontal splitter; updates *size (height of the panel above it)
static void hsplitter(const char *id, float *size, float lo, float hi, float width)
{
  ImGui::PushID(id);
  ImGui::InvisibleButton("##split",ImVec2(width,6.0f));
  bool hovered=ImGui::IsItemHovered();
  bool active=ImGui::IsItemActive();
  if (active) *size=clampf(*size+ImGui::GetIO().MouseDelta.y,lo,hi);
  ImVec2 mn=ImGui::GetItemRectMin(), mx=ImGui::GetItemRectMax();
  ImGui::PopID();
  ImDrawList *dl=ImGui::GetWindowDrawList();
  dl->AddRectFilled(mn,mx,active?IM_COL32(70,120,200,255):hovered?IM_COL32(70,74,86,255):IM_COL32(0,0,0,0),1.0f);
}

static const char *status_text(int st)
{
  switch (st)
  {
    case NJClient::NJC_STATUS_DISCONNECTED: return "disconnected";
    case NJClient::NJC_STATUS_INVALIDAUTH:  return "invalid username/password";
    case NJClient::NJC_STATUS_CANTCONNECT:  return "can't connect";
    case NJClient::NJC_STATUS_OK:           return "connected";
    case NJClient::NJC_STATUS_PRECONNECT:   return "connecting...";
  }
  return "?";
}

static ImVec4 status_color(int st)
{
  switch (st)
  {
    case NJClient::NJC_STATUS_OK:         return kGood;
    case NJClient::NJC_STATUS_PRECONNECT: return kWarn;
    case NJClient::NJC_STATUS_DISCONNECTED: return kDim;
    default: return kBad;
  }
}

// a client that has never connected reports PRECONNECT; show it as disconnected
static int display_status()
{
  int st=g_client.GetStatus();
  if (st == NJClient::NJC_STATUS_PRECONNECT && !g_client.GetHostName()[0])
    return NJClient::NJC_STATUS_DISCONNECTED;
  return st;
}

static void status_pill(int st)
{
  ImVec4 col=status_color(st);
  ImVec2 p=ImGui::GetCursorScreenPos();
  float h=ImGui::GetTextLineHeight();
  float r=5.0f;
  ImGui::GetWindowDrawList()->AddCircleFilled(ImVec2(p.x+r+1.0f,p.y+h*0.5f),r,ImGui::ColorConvertFloat4ToU32(col));
  ImGui::SetCursorPosX(ImGui::GetCursorPosX()+2.0f*r+8.0f);
  ImGui::TextColored(col,"%s",status_text(st));
}

// ---------------------------------------------------------------------------
// top bar / status bar
// ---------------------------------------------------------------------------

static void draw_top_bar()
{
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(16,8));
  ImGui::BeginChild("##topbar",ImVec2(0,ImGui::GetFrameHeight()+18),0,ImGuiWindowFlags_NoScrollbar);

  int st=display_status();
  status_pill(st);

  if (st == NJClient::NJC_STATUS_OK)
  {
    ImGui::SameLine();
    ImGui::TextDisabled("|");
    ImGui::SameLine();
    ImGui::Text("%s @ %s",g_client.GetUser(),g_client.GetHostName());
    ImGui::SameLine();
    ImGui::TextDisabled("|");
    ImGui::SameLine();
    ImGui::Text("%d users",g_client.GetNumUsers()+1);
  }

  // right-aligned session summary
  if (st == NJClient::NJC_STATUS_OK)
  {
    char buf[128];
    unsigned int ms=g_client.GetSessionPosition();
    snprintf(buf,sizeof(buf),"%.0f BPM  %d BPI  %02u:%02u",
             g_client.GetActualBPM(),g_client.GetBPI(),ms/60000,(ms/1000)%60);
    ImVec2 ts=ImGui::CalcTextSize(buf);
    ImGui::SameLine(ImGui::GetWindowWidth()-ts.x-32.0f);
    ImGui::TextUnformatted(buf);
  }

  ImGui::EndChild();
  ImGui::PopStyleVar();
}

static void draw_status_bar()
{
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(16,4));
  ImGui::BeginChild("##statusbar",ImVec2(0,ImGui::GetTextLineHeight()+16),0,ImGuiWindowFlags_NoScrollbar);

  if (g_noaudio)
    ImGui::TextDisabled("audio: disabled (--noaudio)");
  else if (g_audiorunning)
    ImGui::TextDisabled("audio: %d Hz, %d in / %d out",g_srate,g_innch,g_outnch);
  else
    ImGui::TextColored(kBad,"audio: %s",g_audioerr[0]?g_audioerr:"not running");

  int retry_in=g_auto_reconnect.seconds_until_retry(ImGui::GetTime());
  if (retry_in >= 0)
  {
    ImGui::SameLine();
    ImGui::TextColored(kWarn,"reconnecting in %ds",retry_in);
  }

  const char *hint="Enter: send chat   /msg <user> <text>: private   /topic <text>: set topic";
  ImVec2 ts=ImGui::CalcTextSize(hint);
  ImGui::SameLine(ImGui::GetWindowWidth()-ts.x-32.0f);
  ImGui::TextDisabled("%s",hint);

  ImGui::EndChild();
  ImGui::PopStyleVar();
}

// ---------------------------------------------------------------------------
// sidebar: connection / session / output / metronome / recording
// ---------------------------------------------------------------------------

static bool try_connect()
{
  if (!g_hostbuf[0]) return false;
  g_auto_reconnect.manual_connect();
  g_client.SetWorkDir(g_workdir.c_str());
  g_client.Connect(g_hostbuf,g_userbuf,g_passbuf);
  return true;
}

static void update_auto_reconnect()
{
  const double now=ImGui::GetTime();
  g_auto_reconnect.observe(g_client.GetStatus(),now);
  if (g_hostbuf[0] && g_auto_reconnect.begin_retry(now))
  {
    g_client.SetWorkDir(g_workdir.c_str());
    g_client.Connect(g_hostbuf,g_userbuf,g_passbuf);
  }
}

static void draw_connection_section()
{
  ImGui::SeparatorText("Connection");

  int st=display_status();
  status_pill(st);
  bool auto_reconnect=g_auto_reconnect.enabled();
  if (ImGui::Checkbox("Auto-reconnect",&auto_reconnect))
    g_auto_reconnect.set_enabled(auto_reconnect,g_client.GetStatus(),ImGui::GetTime());
  ImGui::Spacing();

  // DISCONNECTED belongs here too since issue #29: a byte stream that stopped
  // parsing and a socket that closed share that one status code, so this
  // string is the only thing that tells them apart.
  if (st == NJClient::NJC_STATUS_DISCONNECTED || st == NJClient::NJC_STATUS_CANTCONNECT || st == NJClient::NJC_STATUS_INVALIDAUTH)
  {
    const char *e=g_client.GetErrorStr();
    if (e && *e)
    {
      ImGui::PushStyleColor(ImGuiCol_Text,kBad);
      ImGui::TextWrapped("%s",e);
      ImGui::PopStyleColor();
    }
    ImGui::Spacing();
  }

  if (st == NJClient::NJC_STATUS_DISCONNECTED || st == NJClient::NJC_STATUS_CANTCONNECT || st == NJClient::NJC_STATUS_INVALIDAUTH)
  {
    ImGui::SetNextItemWidth(-1);
    bool go=ImGui::InputTextWithHint("##host","host[:port]",g_hostbuf,sizeof(g_hostbuf),ImGuiInputTextFlags_EnterReturnsTrue);
    ImGui::SetNextItemWidth(-1);
    go|=ImGui::InputTextWithHint("##user","username",g_userbuf,sizeof(g_userbuf),ImGuiInputTextFlags_EnterReturnsTrue);
    ImGui::SetNextItemWidth(-1);
    go|=ImGui::InputTextWithHint("##pass","password",g_passbuf,sizeof(g_passbuf),ImGuiInputTextFlags_Password|ImGuiInputTextFlags_EnterReturnsTrue);
    if (go) try_connect();
    ImGui::Spacing();
    ImGui::BeginDisabled(!g_hostbuf[0]);
    if (ImGui::Button("Connect",ImVec2(-1,0))) try_connect();
    ImGui::EndDisabled();
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextDisabled("anonymous: use \"anonymous\" or \"anonymous:tag\"");
    ImGui::PopTextWrapPos();
  }
  else
  {
    ImGui::Text("user:  %s",g_client.GetUser());
    ImGui::Text("host:  %s",g_client.GetHostName());
    ImGui::Spacing();
    if (ImGui::Button("Disconnect",ImVec2(-1,0)))
    {
      g_auto_reconnect.manual_disconnect();
      g_client.Disconnect();
    }
  }
}

static void draw_session_section()
{
  if (g_client.GetStatus() != NJClient::NJC_STATUS_OK) return;

  ImGui::SeparatorText("Session");

  ImGui::Text("%.0f BPM",g_client.GetActualBPM());
  ImGui::SameLine(110.0f);
  ImGui::Text("%d BPI",g_client.GetBPI());

  int pos=0,len=1;
  g_client.GetPosition(&pos,&len);
  if (len < 1) len=1;
  int srate=g_client.GetSampleRate(); if (srate <= 0) srate=g_srate;
  double secleft=(len > pos) ? (double)(len-pos)/(double)srate : 0.0;
  char overlay[64];
  snprintf(overlay,sizeof(overlay),"next interval in %.0fs",secleft);
  ImGui::ProgressBar((float)pos/(float)len,ImVec2(-1,0),overlay);

  unsigned int ms=g_client.GetSessionPosition();
  ImGui::Text("session %02u:%02u",ms/60000,(ms/1000)%60);
  ImGui::SameLine(140.0f);
  ImGui::Text("loop %d",g_client.GetLoopCount());
}

static void draw_mix_section()
{
  ImGui::SeparatorText("Output");

  float lw=64.0f;
  ImGui::TextDisabled("L");
  ImGui::SameLine();
  peak_meter("##outL",g_client.GetOutputPeak(0),ImGui::GetContentRegionAvail().x-lw-ImGui::GetStyle().ItemSpacing.x);
  ImGui::SameLine();
  dB_text(g_client.config_mastervolume);
  ImGui::TextDisabled("R");
  ImGui::SameLine();
  peak_meter("##outR",g_client.GetOutputPeak(1),ImGui::GetContentRegionAvail().x-lw-ImGui::GetStyle().ItemSpacing.x);
  ImGui::SameLine();
  dB_text(g_client.config_mastervolume);

  ImGui::Spacing();
  mixer_row("master",&g_client.config_mastervolume,&g_client.config_masterpan,&g_client.config_mastermute,NULL);

  ImGui::SeparatorText("Metronome");
  mixer_row("metro",&g_client.config_metronome,&g_client.config_metronome_pan,&g_client.config_metronome_mute,NULL);
}

static void draw_recording_section()
{
  ImGui::SeparatorText("Recording");

  static const char *recmodes[]={ "discard received audio","keep .ogg recordings","keep .ogg + .wav recordings" };
  int recmode=0;
  if (g_client.config_savelocalaudio > 1) recmode=2;
  else if (g_client.config_savelocalaudio > 0) recmode=1;
  ImGui::SetNextItemWidth(-1);
  if (ImGui::Combo("##recmode",&recmode,recmodes,3))
    g_client.config_savelocalaudio=recmode;

  ImGui::TextDisabled("work dir: %s",g_client.GetWorkDir());
}

// ---------------------------------------------------------------------------
// local channels
// ---------------------------------------------------------------------------

static void draw_local_channel_card(int ch, float cardw)
{
  ImGui::PushID(ch);
  LocalChanUI &ui=g_localui[ch];

  int srcch=0,bitrate=64;
  bool bcast=false;
  const char *nm=g_client.GetLocalChannelInfo(ch,&srcch,&bitrate,&bcast);
  if (ui.name.empty() && nm) ui.name=nm;

  float rowh=ImGui::GetFrameHeight();
  float sp=ImGui::GetStyle().ItemSpacing.y;
  float cardh=24.0f+rowh*3.0f+14.0f+3.0f*sp;

  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(12,10));
  ImGui::PushStyleColor(ImGuiCol_ChildBg,kCardBg);
  ImGui::BeginChild("##card",ImVec2(cardw,cardh),ImGuiChildFlags_Borders,ImGuiWindowFlags_NoScrollbar);

  float W=ImGui::GetContentRegionAvail().x;
  float ispx=ImGui::GetStyle().ItemSpacing.x;

  // row 1: name + remove
  ImGui::SetNextItemWidth(W-32.0f-ispx);
  if (ImGui::InputText("##name",&ui.name))
    g_client.SetLocalChannelInfo(ch,ui.name.c_str(),false,0,false,0,false,false);
  ImGui::SameLine(0.0f,ispx);
  if (ImGui::Button("x",ImVec2(28,0)))
  {
    g_client.DeleteLocalChannel(ch);
    g_client.NotifyServerOfChannelChange();
    g_localui.erase(ch);
    ImGui::EndChild();
    ImGui::PopStyleColor();
    ImGui::PopStyleVar();
    ImGui::PopID();
    return;
  }
  ImGui::SetItemTooltip("remove channel");

  // row 2: meter
  char idbuf[32];
  snprintf(idbuf,sizeof(idbuf),"##lcmeter%d",ch);
  peak_meter(idbuf,g_client.GetLocalChannelPeak(ch),W,14.0f);

  // row 3: monitor mix
  float vol=1.0f,pan=0.0f;
  bool mute=false,solo=false;
  g_client.GetLocalChannelMonitoring(ch,&vol,&pan,&mute,&solo);
  int mc=mixer_row("mon",&vol,&pan,&mute,&solo);
  if (mc&1) g_client.SetLocalChannelMonitoring(ch,true,vol,true,pan,false,false,false,false);
  if (mc&2) g_client.SetLocalChannelMonitoring(ch,false,0,false,0,true,mute,false,false);
  if (mc&4) g_client.SetLocalChannelMonitoring(ch,false,0,false,0,false,false,true,solo);

  // row 4: input source, bitrate, broadcast
  static const int bitrates[]={ 32,48,64,96,128,192,256,320 };
  char brstr[8][8];
  const char *brptr[8];
  int cursel=2;
  for (int b = 0; b < 8; b ++)
  {
    snprintf(brstr[b],8,"%dk",bitrates[b]);
    brptr[b]=brstr[b];
    if (bitrates[b] == ui.bitrate) cursel=b;
  }
  ImGui::SetNextItemWidth(118.0f);
  if (ImGui::Combo("##bitrate",&cursel,brptr,8))
  {
    ui.bitrate=bitrates[cursel];
    g_client.SetLocalChannelInfo(ch,NULL,false,0,true,ui.bitrate,false,false);
    g_client.NotifyServerOfChannelChange();
  }
  ImGui::SetItemTooltip("encoder bitrate");

  ImGui::SameLine(0.0f,ispx);
  ImGui::SetNextItemWidth(104.0f);
  int srccursel=srcch;
  char srcstr[8][12];
  const char *srcptr[8];
  int nsrc=g_innch < 8 ? g_innch : 8;
  for (int s = 0; s < nsrc; s ++)
  {
    snprintf(srcstr[s],12,"input %d",s);
    srcptr[s]=srcstr[s];
  }
  srccursel=srcch < nsrc ? srcch : 0;
  if (ImGui::Combo("##src",&srccursel,srcptr,nsrc))
  {
    g_client.SetLocalChannelInfo(ch,NULL,true,srccursel,false,0,false,false);
    g_client.NotifyServerOfChannelChange();
  }
  ImGui::SetItemTooltip("audio input source");

  ImGui::SameLine(0.0f,ispx);
  if (bcast) ImGui::PushStyleColor(ImGuiCol_Button,kAccent);
  if (ImGui::Button(bcast ? "broadcasting" : "broadcast",ImVec2(132,0)))
  {
    g_client.SetLocalChannelInfo(ch,NULL,false,0,false,0,true,!bcast);
    g_client.NotifyServerOfChannelChange();
  }
  if (bcast) ImGui::PopStyleColor();
  ImGui::SetItemTooltip("send this channel to the server");

  ImGui::EndChild();
  ImGui::PopStyleColor();
  ImGui::PopStyleVar();
  ImGui::PopID();
}

static void draw_local_panel(float width, float height)
{
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(12,10));
  ImGui::BeginChild("##local",ImVec2(width,height),ImGuiChildFlags_Borders);

  int nch=0;
  for (int i = 0; g_client.EnumLocalChannels(i) >= 0; i ++) nch++;

  ImGui::SeparatorText("Local channels");
  ImGui::BeginDisabled(nch >= g_client.GetMaxLocalChannels());
  if (ImGui::Button("+ add channel"))
  {
    int idx=-1;
    for (int cand = 0; cand < g_client.GetMaxLocalChannels() && idx < 0; cand ++)
    {
      bool used=false;
      for (int i = 0; !used; i ++)
      {
        int ch=g_client.EnumLocalChannels(i);
        if (ch < 0) break;
        if (ch == cand) used=true;
      }
      if (!used) idx=cand;
    }
    if (idx >= 0)
    {
      char nm[32];
      snprintf(nm,sizeof(nm),"channel %d",idx+1);
      g_client.SetLocalChannelInfo(idx,nm,true,0,true,64,true,true);
      g_client.NotifyServerOfChannelChange();
    }
  }
  ImGui::EndDisabled();
  if (nch >= g_client.GetMaxLocalChannels())
  {
    ImGui::SameLine();
    ImGui::TextDisabled("(%d/%d)",nch,g_client.GetMaxLocalChannels());
  }

  ImGui::Spacing();
  float cardw=ImGui::GetContentRegionAvail().x;
  for (int i = 0;; i ++)
  {
    int ch=g_client.EnumLocalChannels(i);
    if (ch < 0) break;
    draw_local_channel_card(ch,cardw);
  }
  if (nch == 0)
    ImGui::TextDisabled("no local channels - add one to start sending audio");

  ImGui::EndChild();
  ImGui::PopStyleVar();
}

// ---------------------------------------------------------------------------
// remote users
// ---------------------------------------------------------------------------

static void draw_user_card(int u, float cardw)
{
  ImGui::PushID(u);

  float vol=1.0f,pan=0.0f;
  bool mute=false;
  const char *name=g_client.GetUserState(u,&vol,&pan,&mute);

  int nch=0;
  for (int ci = 0; g_client.EnumUserChannels(u,ci) >= 0; ci ++) nch++;

  float rowh=ImGui::GetFrameHeight();
  float sp=ImGui::GetStyle().ItemSpacing.y;
  float cardh=24.0f+rowh*(1.0f+nch)+nch*sp;

  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(12,10));
  ImGui::PushStyleColor(ImGuiCol_ChildBg,kCardBg);
  ImGui::BeginChild("##card",ImVec2(cardw,cardh),ImGuiChildFlags_Borders,ImGuiWindowFlags_NoScrollbar);

  float W=ImGui::GetContentRegionAvail().x;
  float ispx=ImGui::GetStyle().ItemSpacing.x;

  // header row: name | vol | pan | mute
  float namecol=W*0.30f; if (namecol < 130.0f) namecol=130.0f;
  text_fit(name,namecol-10.0f);
  ImGui::SameLine(namecol);
  float mixavail=W-namecol-26.0f-2.0f*ispx;
  ImGui::SetNextItemWidth(mixavail*0.56f);
  bool uv=ImGui::SliderFloat("##uvol",&vol,0.0f,2.0f,"vol %.2f");
  ImGui::SameLine(0.0f,ispx);
  ImGui::SetNextItemWidth(mixavail*0.44f);
  uv|=ImGui::SliderFloat("##upan",&pan,-1.0f,1.0f,"pan %.2f");
  ImGui::SameLine(0.0f,ispx);
  if (ImGui::Checkbox("##umute",&mute))
    g_client.SetUserState(u,false,0,false,0,true,mute);
  ImGui::SetItemTooltip("mute this user");
  if (uv) g_client.SetUserState(u,true,vol,true,pan,false,false);

  // channel rows
  for (int ci = 0;; ci ++)
  {
    int ch=g_client.EnumUserChannels(u,ci);
    if (ch < 0) break;

    bool sub=false,cmute=false,csolo=false;
    float cvol=1.0f,cpan=0.0f;
    const char *cname=g_client.GetUserChannelState(u,ch,&sub,&cvol,&cpan,&cmute,&csolo);

    ImGui::PushID(ch);

    float namecol=W*0.26f; if (namecol < 90.0f) namecol=90.0f;
    float meterw=90.0f,panw=90.0f,flagw=26.0f;
    float volw=W-namecol-meterw-panw-2.0f*flagw-5.0f*ispx;
    if (volw < 70.0f) volw=70.0f;

    float x0=ImGui::GetCursorPosX();
    if (ImGui::Checkbox("##sub",&sub))
      g_client.SetUserChannelState(u,ch,true,sub,false,0,false,0,false,false,false,false);
    ImGui::SetItemTooltip("subscribe to this channel");

    ImGui::SameLine(x0+30.0f);
    text_fit(cname,namecol-34.0f);

    ImGui::SameLine(x0+namecol);
    ImGui::SetCursorPosY(ImGui::GetCursorPosY()+(ImGui::GetFrameHeight()-12.0f)*0.5f);
    char meterid[64];
    snprintf(meterid,sizeof(meterid),"##ucmeter%d_%d",u,ch);
    peak_meter(meterid,g_client.GetUserChannelPeak(u,ch),meterw,12.0f);

    ImGui::SameLine(x0+namecol+meterw+ispx);
    ImGui::SetNextItemWidth(volw);
    bool cv=ImGui::SliderFloat("##cvol",&cvol,0.0f,2.0f,"vol %.2f");
    ImGui::SameLine(0.0f,ispx);
    ImGui::SetNextItemWidth(panw);
    cv|=ImGui::SliderFloat("##cpan",&cpan,-1.0f,1.0f,"pan %.2f");
    ImGui::SameLine(0.0f,ispx);
    if (ImGui::Checkbox("##cmute",&cmute))
      g_client.SetUserChannelState(u,ch,false,false,false,0,false,0,true,cmute,false,false);
    ImGui::SetItemTooltip("mute channel");
    ImGui::SameLine(0.0f,ispx);
    if (ImGui::Checkbox("##csolo",&csolo))
      g_client.SetUserChannelState(u,ch,false,false,false,0,false,0,false,false,true,csolo);
    ImGui::SetItemTooltip("solo channel");
    if (cv) g_client.SetUserChannelState(u,ch,false,false,true,cvol,true,cpan,false,false,false,false);

    ImGui::PopID();
  }

  ImGui::EndChild();
  ImGui::PopStyleColor();
  ImGui::PopStyleVar();
  ImGui::PopID();
}

static void draw_users_panel(float width, float height)
{
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(12,10));
  ImGui::BeginChild("##users",ImVec2(width,height),ImGuiChildFlags_Borders);

  ImGui::SeparatorText("Remote users");
  if (g_client.IsASoloActive())
  {
    ImGui::SameLine();
    ImGui::TextColored(kWarn,"SOLO active");
  }

  ImGui::Spacing();
  float cardw=ImGui::GetContentRegionAvail().x;
  for (int u = 0; u < g_client.GetNumUsers(); u ++)
    draw_user_card(u,cardw);
  if (g_client.GetNumUsers() == 0)
    ImGui::TextDisabled(g_client.GetStatus() == NJClient::NJC_STATUS_OK ? "nobody else is here yet" : "connect to see remote users");

  ImGui::EndChild();
  ImGui::PopStyleVar();
}

// ---------------------------------------------------------------------------
// chat
// ---------------------------------------------------------------------------

static void draw_chat_panel(float width, float height)
{
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(12,10));
  ImGui::BeginChild("##chat",ImVec2(width,height),ImGuiChildFlags_Borders);

  ImGui::SeparatorText("Chat");

  float inputh=ImGui::GetFrameHeight();
  ImGui::BeginChild("##chatlines",ImVec2(0,-inputh-ImGui::GetStyle().ItemSpacing.y-6.0f),0);
  ImGui::PushTextWrapPos(0.0f); // wrap long lines at the panel edge

  for (size_t x = 0; x < g_chatlines.size(); x ++)
  {
    const std::string &s=g_chatlines[x];
    if (s.compare(0,3,"***") == 0)
    {
      ImGui::TextDisabled("%s",s.c_str());
    }
    else if (s.compare(0,9,"[private ") == 0)
    {
      ImGui::TextColored(kWarn,"%s",s.c_str());
    }
    else
    {
      // color the speaker name (up to the first ": ")
      size_t colon=s.find(": ");
      if (colon != std::string::npos && colon > 0 && colon < 24)
      {
        unsigned int h=2166136261u;
        for (size_t i = 0; i < colon; i ++) { h^=(unsigned char)s[i]; h*=16777619u; }
        ImVec4 col=ImColor::HSV((h%360)/360.0f,0.55f,0.92f);
        ImGui::TextColored(col,"%s",s.substr(0,colon).c_str());
        ImGui::SameLine(0.0f,0.0f);
        ImGui::TextUnformatted(s.c_str()+colon);
      }
      else
      {
        ImGui::TextUnformatted(s.c_str());
      }
    }
  }
  ImGui::PopTextWrapPos();

  // auto-scroll unless the user has scrolled up to read history
  if (g_chatscroll) ImGui::SetScrollHereY(1.0f);
  g_chatscroll=(ImGui::GetScrollY() >= ImGui::GetScrollMaxY()-4.0f);
  ImGui::EndChild();

  ImGui::SetNextItemWidth(-88.0f-ImGui::GetStyle().ItemSpacing.x);
  bool send=ImGui::InputTextWithHint("##chatinput","type a message...",g_chatinput,sizeof(g_chatinput),ImGuiInputTextFlags_EnterReturnsTrue);
  ImGui::SameLine(0.0f,ImGui::GetStyle().ItemSpacing.x);
  if (ImGui::Button("Send",ImVec2(88,0))) send=true;

  if (send && g_chatinput[0] && g_client.GetStatus() == NJClient::NJC_STATUS_OK)
  {
    if (!strncmp(g_chatinput,"/msg ",5))
    {
      char *p=g_chatinput+5;
      char *sp=strchr(p,' ');
      if (sp)
      {
        *sp=0;
        g_client.ChatMessage_Send("PRIVMSG",p,sp+1);
      }
    }
    else if (!strncmp(g_chatinput,"/topic ",7))
    {
      std::string topic_command="topic ";
      topic_command+=g_chatinput+7;
      g_client.ChatMessage_Send("ADMIN",topic_command.c_str());
    }
    else
      g_client.ChatMessage_Send("MSG",g_chatinput);
    g_chatinput[0]=0;
    g_chatscroll=true;
  }

  ImGui::EndChild();
  ImGui::PopStyleVar();
}

// ---------------------------------------------------------------------------
// full UI
// ---------------------------------------------------------------------------

void ui_draw()
{
  update_auto_reconnect();

  // Note: use DisplaySize rather than the main viewport's WorkPos/WorkSize -
  // without ImGuiConfigFlags_ViewportsEnable the work rect is never updated.
  ImGuiIO &io=ImGui::GetIO();
  ImGui::SetNextWindowPos(ImVec2(0,0));
  ImGui::SetNextWindowSize(io.DisplaySize);
  ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding,0.0f);
  ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize,0.0f);
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(0,0));
  ImGui::Begin("##shell",NULL,
    ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoResize|
    ImGuiWindowFlags_NoSavedSettings|ImGuiWindowFlags_NoBringToFrontOnFocus|
    ImGuiWindowFlags_NoNavFocus|ImGuiWindowFlags_NoScrollbar);
  ImGui::PopStyleVar(3);

  draw_top_bar();

  const float spl=6.0f;
  ImGuiStyle &style=ImGui::GetStyle();

  float midH=ImGui::GetContentRegionAvail().y-ImGui::GetTextLineHeight()-16.0f-style.ItemSpacing.y;

  // resolve default split sizes once the first frame knows the window size
  {
    float midW=ImGui::GetContentRegionAvail().x-2.0f*spl;
    const float minc=520.0f; // keep the center mixer column usable
    g_sidebarw=clampf(g_sidebarw,280.0f,midW-g_chatw-minc-spl);
    g_chatw=clampf(g_chatw,320.0f,midW-g_sidebarw-minc-spl);
    if (g_localh <= 0.0f) g_localh=midH*0.42f;
  }

  float centerw=ImGui::GetContentRegionAvail().x-g_sidebarw-g_chatw-2.0f*spl;

  // sidebar
  ImGui::BeginChild("##sidebar",ImVec2(g_sidebarw,midH),ImGuiChildFlags_Borders);
  draw_connection_section();
  draw_session_section();
  draw_mix_section();
  draw_recording_section();
  ImGui::EndChild();

  ImGui::SameLine(0.0f,0.0f);
  vsplitter("##sp1",&g_sidebarw,280.0f,520.0f,midH);
  ImGui::SameLine(0.0f,0.0f);

  // center column: local channels over remote users
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(0,0));
  ImGui::BeginChild("##center",ImVec2(centerw,midH),0,ImGuiWindowFlags_NoScrollbar);
  {
    float cw=ImGui::GetContentRegionAvail().x;
    float ch=ImGui::GetContentRegionAvail().y;
    float sp3=ImGui::GetStyle().ItemSpacing.y;
    float usersH=ch-g_localh-spl-2.0f*sp3;
    if (usersH < 150.0f) { usersH=150.0f; g_localh=ch-usersH-spl-2.0f*sp3; }
    draw_local_panel(cw,g_localh);
    hsplitter("##sp3",&g_localh,150.0f,ch-150.0f-spl-2.0f*sp3,cw);
    draw_users_panel(cw,usersH);
  }
  ImGui::EndChild();
  ImGui::PopStyleVar();

  ImGui::SameLine(0.0f,0.0f);
  vsplitter("##sp2",&g_chatw,320.0f,600.0f,midH,true);
  ImGui::SameLine(0.0f,0.0f);

  // chat column
  draw_chat_panel(g_chatw,midH);

  draw_status_bar();

  ImGui::End();
}

// ---------------------------------------------------------------------------
// exported API (see ui.h)
// ---------------------------------------------------------------------------

void ui_setup_context()
{
  ImGuiIO &io=ImGui::GetIO();
  io.ConfigFlags|=ImGuiConfigFlags_NavEnableKeyboard;
  io.IniFilename=NULL; // layout is fully custom
  {
    // crisp text on HiDPI displays: rasterize the default font larger
    ImFontConfig fc;
    fc.SizePixels=17.0f;
    io.Fonts->AddFontDefault(&fc);
  }
  apply_style();
}

void ui_reset()
{
  // remove all local channels (collect first: indices shift while deleting)
  std::vector<int> chans;
  for (int i = 0;; i ++)
  {
    int ch=g_client.EnumLocalChannels(i);
    if (ch < 0) break;
    chans.push_back(ch);
  }
  for (size_t i = 0; i < chans.size(); i ++) g_client.DeleteLocalChannel(chans[i]);

  // restore the NJClient defaults so state can't leak between snapshots
  g_client.config_savelocalaudio=0;
  g_client.config_metronome=0.5f;
  g_client.config_metronome_pan=0.0f;
  g_client.config_metronome_mute=false;
  g_client.config_mastervolume=1.0f;
  g_client.config_masterpan=0.0f;
  g_client.config_mastermute=false;

  g_chatlines.clear();
  g_chatscroll=true;
  g_chatinput[0]=0;
  g_localui.clear();
  g_meterholds.clear();
  g_sidebarw=318.0f;
  g_chatw=372.0f;
  g_localh=0.0f;
  g_auto_reconnect.reset();
}

NJClient *ui_client()
{
  return &g_client;
}

int ui_draw_license_modal(const char *licensetext)
{
  int answer=-1;

  // dim the main UI behind the modal
  ImGui::GetForegroundDrawList()->AddRectFilled(
    ImVec2(0,0),ImGui::GetIO().DisplaySize,IM_COL32(0,0,0,150));

  ImGuiIO &io=ImGui::GetIO();
  float mw=io.DisplaySize.x-120.0f; if (mw > 720.0f) mw=720.0f;
  float mh=io.DisplaySize.y-120.0f; if (mh > 560.0f) mh=560.0f;
  ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x*0.5f,io.DisplaySize.y*0.5f),ImGuiCond_Always,ImVec2(0.5f,0.5f));
  ImGui::SetNextWindowSize(ImVec2(mw,mh),ImGuiCond_Always);
  ImGui::Begin("Server license agreement",NULL,ImGuiWindowFlags_NoCollapse|ImGuiWindowFlags_NoResize|ImGuiWindowFlags_NoSavedSettings);
  ImGui::TextWrapped("The server requires you to accept this agreement before joining:");
  ImGui::Spacing();
  ImGui::BeginChild("##lictext",ImVec2(0,-46),ImGuiChildFlags_Borders);
  ImGui::TextUnformatted(licensetext?licensetext:"");
  ImGui::EndChild();
  ImGui::Spacing();
  {
    float bw=160.0f;
    float x=ImGui::GetCursorPosX()+ImGui::GetContentRegionAvail().x-2.0f*bw-ImGui::GetStyle().ItemSpacing.x;
    ImGui::SetCursorPosX(x);
    if (ImGui::Button("Accept",ImVec2(bw,0))) answer=1;
    ImGui::SameLine();
    if (ImGui::Button("Decline",ImVec2(bw,0)) || ImGui::IsKeyPressed(ImGuiKey_Escape,false)) answer=0;
  }
  ImGui::End();
  return answer;
}

void ui_set_audio_status(bool noaudio, bool running, int srate, int innch, int outnch, const char *err)
{
  g_noaudio=noaudio;
  g_audiorunning=running;
  if (srate > 0) g_srate=srate;
  if (innch > 0) g_innch=innch;
  if (outnch > 0) g_outnch=outnch;
  snprintf(g_audioerr,sizeof(g_audioerr),"%s",err?err:"");
}

void ui_set_connect_fields(const char *host, const char *user, const char *pass)
{
  snprintf(g_hostbuf,sizeof(g_hostbuf),"%s",host?host:"");
  snprintf(g_userbuf,sizeof(g_userbuf),"%s",user?user:"");
  snprintf(g_passbuf,sizeof(g_passbuf),"%s",pass?pass:"");
}

void ui_set_workdir(const char *dir)
{
  g_workdir=(dir && *dir) ? dir : "ninjam-audio";
  g_client.SetWorkDir(g_workdir.c_str());
}

void ui_set_auto_reconnect(bool enabled)
{
  g_auto_reconnect.set_enabled(enabled,g_client.GetStatus(),0.0);
}

bool ui_auto_reconnect_enabled()
{
  return g_auto_reconnect.enabled();
}

bool ui_try_connect()
{
  return try_connect();
}

const char *ui_connect_host()
{
  return g_hostbuf;
}

void ui_format_title(char *buf, int bufsize)
{
  int st=display_status();
  if (st == NJClient::NJC_STATUS_OK)
    snprintf(buf,bufsize,"NINJAM - %s @ %s",g_client.GetUser(),g_client.GetHostName());
  else if (g_hostbuf[0])
    snprintf(buf,bufsize,"NINJAM - %s (%s)",g_hostbuf,status_text(st));
  else
    snprintf(buf,bufsize,"NINJAM");
}
