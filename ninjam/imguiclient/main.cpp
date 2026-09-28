/*
    NINJAM client - main.cpp

    Revived cross-platform NINJAM GUI client:
      - Dear ImGui + GLFW + OpenGL3 for the UI (drawing lives in ui.cpp)
      - miniaudio for duplex audio I/O (see audio_engine.cpp)
      - NJClient (the modernized core) for the NINJAM protocol

    Threading model (see njclient.h):
      - NJClient::Run() and all UI/state access happen on the main (UI) thread
      - NJClient::AudioProc() is called from the audio thread only; NJClient
        protects that internally
      - the server license agreement is shown as a nested modal loop from
        inside the NJClient license callback (same pattern the original
        clients used with native modal dialogs)
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>

#include "ninjam/njclient.h"

#include "audio_engine.h"
#include "ui.h"

#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"
#if defined(__APPLE__)
#define GL_SILENCE_DEPRECATION
#endif
#include <GLFW/glfw3.h>
#if defined(__APPLE__)
#include <OpenGL/gl.h>
#else
#include <GL/gl.h>
#endif

// ---------------------------------------------------------------------------
// globals
// ---------------------------------------------------------------------------

static AudioEngine g_audio;
static GLFWwindow *g_window;

static int g_srate=48000;
static int g_innch=2, g_outnch=2;
static bool g_noaudio=false;
static std::string g_workdir="ninjam-audio";

// ---------------------------------------------------------------------------
// NJClient callbacks
// ---------------------------------------------------------------------------

static void chat_cb(void *userData, NJClient *inst, const char **parms, int nparms)
{
  (void)userData; (void)inst;
  ui_chat_message(parms,nparms);
}

static int license_cb(void *userData, const char *licensetext)
{
  (void)userData;
  // We are on the UI thread inside NJClient::Run(). Run a nested ImGui frame
  // loop until the user answers (or times out / closes the window).
  int answer=-1;
  double t0=glfwGetTime();
  while (answer < 0 && !glfwWindowShouldClose(g_window))
  {
    if (glfwGetTime()-t0 > 300.0) break; // 5 min timeout: decline

    glfwPollEvents();

    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplGlfw_NewFrame();
    ImGui::NewFrame();

    ui_draw();
    answer=ui_draw_license_modal(licensetext);

    ImGui::Render();
    int w,h;
    glfwGetFramebufferSize(g_window,&w,&h);
    glViewport(0,0,w,h);
    glClearColor(0.10f,0.10f,0.12f,1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
    glfwSwapBuffers(g_window);
  }
  return answer > 0 ? 1 : 0;
}

static void audio_proc(float **inbuf, int innch, float **outbuf, int outnch, int len, int srate, void *user)
{
  ((NJClient *)user)->AudioProc(inbuf,innch,outbuf,outnch,len,srate);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

static void usage()
{
  printf("ninjam-client [--host host[:port]] [--user name] [--pass pass] [--srate hz] [--workdir dir] [--noaudio]\n");
}

int main(int argc, char **argv)
{
  bool doconnect=false;
  char hostbuf[256]="", userbuf[128]="", passbuf[128]="";
  for (int x = 1; x < argc; x ++)
  {
    if (!strcmp(argv[x],"--host") && x+1 < argc) { snprintf(hostbuf,sizeof(hostbuf),"%s",argv[++x]); doconnect=true; }
    else if (!strcmp(argv[x],"--user") && x+1 < argc) snprintf(userbuf,sizeof(userbuf),"%s",argv[++x]);
    else if (!strcmp(argv[x],"--pass") && x+1 < argc) snprintf(passbuf,sizeof(passbuf),"%s",argv[++x]);
    else if (!strcmp(argv[x],"--srate") && x+1 < argc) g_srate=atoi(argv[++x]);
    else if (!strcmp(argv[x],"--noaudio")) g_noaudio=true;
    else if (!strcmp(argv[x],"--workdir") && x+1 < argc) g_workdir=argv[++x];
    else if (!strcmp(argv[x],"--help")) { usage(); return 0; }
    else { usage(); return 1; }
  }

  ui_set_connect_fields(hostbuf,userbuf,passbuf);
  ui_set_workdir(g_workdir.c_str());

  NJClient *client=ui_client();
  client->ChatMessage_Callback=chat_cb;
  client->LicenseAgreementCallback=license_cb;
  client->SetWorkDir(g_workdir.c_str());

  if (!glfwInit())
  {
    fprintf(stderr,"glfwInit failed\n");
    return 1;
  }

  glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR,3);
  glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR,2);
  glfwWindowHint(GLFW_OPENGL_PROFILE,GLFW_OPENGL_CORE_PROFILE);
#ifdef __APPLE__
  glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT,GL_TRUE);
#endif

  g_window=glfwCreateWindow(1360,880,"NINJAM",NULL,NULL);
  if (!g_window)
  {
    fprintf(stderr,"window creation failed\n");
    glfwTerminate();
    return 1;
  }
  glfwSetWindowSizeLimits(g_window,1240,680,GLFW_DONT_CARE,GLFW_DONT_CARE);
  glfwMakeContextCurrent(g_window);
  glfwSwapInterval(1);

  IMGUI_CHECKVERSION();
  ImGui::CreateContext();
  ImGui::GetIO().IniFilename=NULL;
  ui_setup_context();

  ImGui_ImplGlfw_InitForOpenGL(g_window,true);
  ImGui_ImplOpenGL3_Init("#version 150");

  if (g_noaudio)
    fprintf(stderr,"running without audio (--noaudio)\n");
  else if (!g_audio.Start(g_srate,g_innch,g_outnch,audio_proc,client))
    fprintf(stderr,"audio start failed: %s (continuing without audio)\n",g_audio.GetError());
  ui_set_audio_status(g_noaudio,g_audio.IsRunning(),g_audio.GetSampleRate(),g_innch,g_outnch,g_audio.GetError());

  if (doconnect && hostbuf[0]) ui_try_connect();

  int lasttitle_st=-999;
  std::string lasttitle_host;

  while (!glfwWindowShouldClose(g_window))
  {
    glfwPollEvents();

    // drive the network from the UI thread
    int sleepok=client->Run();
    for (int spins = 0; !sleepok && spins < 64; spins ++) sleepok=client->Run();

    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplGlfw_NewFrame();
    ImGui::NewFrame();

    ui_draw();

    // keep the window title in sync with the connection state
    int st=client->GetStatus();
    if (st != lasttitle_st || lasttitle_host != ui_connect_host())
    {
      lasttitle_st=st;
      lasttitle_host=ui_connect_host();
      char title[320];
      ui_format_title(title,sizeof(title));
      glfwSetWindowTitle(g_window,title);
    }

    ImGui::Render();
    int w,h;
    glfwGetFramebufferSize(g_window,&w,&h);
    glViewport(0,0,w,h);
    glClearColor(0.10f,0.10f,0.12f,1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
    glfwSwapBuffers(g_window);
  }

  client->Disconnect();
  g_audio.Stop();

  ImGui_ImplOpenGL3_Shutdown();
  ImGui_ImplGlfw_Shutdown();
  ImGui::DestroyContext();
  glfwDestroyWindow(g_window);
  glfwTerminate();
  return 0;
}
