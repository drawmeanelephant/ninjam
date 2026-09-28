/*
    NINJAM client - Windows stubs for the legacy Jesusonic host.

    The CMake GUI client uses the cross-platform audio engine and does not
    embed the legacy Windows Jesusonic host. njmisc.cpp still provides its
    helper functions for legacy clients, so define the host globals here for
    the modern client/core build.
*/

#ifdef _WIN32

#include "njmisc.h"

WDL_String jesusdir;
jesusonicAPI *JesusonicAPI = 0;

#endif
