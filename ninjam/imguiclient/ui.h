/*
    NINJAM client - ui.h

    Interface to the shared UI layer (ui.cpp). It is used by:
      - main.cpp                    the real GLFW + OpenGL3 client
      - ninjam/tests/ui_snapshot.cpp the offscreen visual-regression harness

    ui.cpp deliberately has no GLFW/OpenGL/backend dependencies: it only draws
    into Dear ImGui, so it can be rendered offscreen to a PNG.
*/

#ifndef _NINJAM_UI_H_
#define _NINJAM_UI_H_

class NJClient;

// call once after ImGui::CreateContext(): loads the font and applies the theme
void ui_setup_context();

// clears chat, channel cards, local channels, meter holds and splitter sizes
// back to the defaults (used between snapshot scenarios)
void ui_reset();

// the NJClient instance the UI drives (owned by ui.cpp)
NJClient *ui_client();

// draws the whole shell; call between ImGui::NewFrame() and ImGui::Render()
void ui_draw();

// draws the dimmed server-license modal on top of the UI.
// returns 1 = accepted, 0 = declined, -1 = still pending
int ui_draw_license_modal(const char *licensetext);

// appends a line to the chat panel
void ui_add_chat_line(const char *line);

// feeds a protocol chat message ("MSG"/"PRIVMSG"/"TOPIC"/"JOIN"/"PART", ...)
// through the chat formatting and into the chat panel
void ui_chat_message(const char **parms, int nparms);

// status bar / audio input source info
void ui_set_audio_status(bool noaudio, bool running, int srate, int innch, int outnch, const char *err);

// connection form state
void ui_set_connect_fields(const char *host, const char *user, const char *pass);
void ui_set_workdir(const char *dir);
bool ui_try_connect();  // starts a connection using the form fields
const char *ui_connect_host();

// formats the window title from the current state ("NINJAM - user @ host", ...)
void ui_format_title(char *buf, int bufsize);

#endif
