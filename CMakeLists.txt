# NINJAM — network jam session system (server + client core + GUI client)
#
# Targets:
#   ninjam_net   — protocol + transport (mpb/netmsg + jnetlib + WDL sha/rng)
#   ninjam_core  — the NJClient client core (requires Ogg/Vorbis)
#   ninjamsrv    — the NINJAM server (option NINJAM_BUILD_SERVER)
#   ninjam-client— cross-platform GUI jam client (option NINJAM_BUILD_CLIENT)
#   ninjam_tests — unit tests (option NINJAM_BUILD_TESTS)
#
# Legacy code that is intentionally not built: the old client ports under
# ninjam/{winclient,guiclient,cocoaclient,cursesclient,cmdclient--old,
# ninjamcast,autosong,cliplogcvt,ks,njasiodrv}, the ReaNINJAM VST plug-in in
# jmde/fx/reaninjam (needs the VST2 SDK), and the source drops in clients/.

cmake_minimum_required(VERSION 3.20)

# Third-party projects fetched below still declare pre-3.5 cmake_minimum_required;
# CMake 4.x removed that compatibility unless we raise the policy floor.
set(CMAKE_POLICY_VERSION_MINIMUM 3.5)

project(ninjam
  VERSION 0.1.0
  DESCRIPTION "NINJAM network jam session server and clients"
  LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()

# all executables land in build/bin/
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

option(NINJAM_BUILD_SERVER "Build the NINJAM server (ninjamsrv)" ON)
option(NINJAM_BUILD_CLIENT "Build the NINJAM GUI client" ON)
option(NINJAM_BUILD_TESTS "Build unit tests" ON)

# Keep dependencies static so the resulting binaries are self-contained.
set(BUILD_SHARED_LIBS OFF)

include(FetchContent)

# ---------------------------------------------------------------------------
# Ogg/Vorbis (required by NJClient: the wire protocol carries Vorbis audio)
# ---------------------------------------------------------------------------
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(VORBIS QUIET IMPORTED_TARGET ogg vorbis vorbisenc)
endif()

if(TARGET PkgConfig::VORBIS)
  set(NINJAM_VORBIS_TARGETS PkgConfig::VORBIS)
else()
  FetchContent_Declare(ogg
    GIT_REPOSITORY https://github.com/xiph/ogg.git
    GIT_TAG v1.3.6
    GIT_SHALLOW TRUE)
  FetchContent_Declare(vorbis
    GIT_REPOSITORY https://github.com/xiph/vorbis.git
    GIT_TAG v1.3.7
    GIT_SHALLOW TRUE)

  set(OGG_INSTALL OFF CACHE BOOL "" FORCE)
  set(BUILD_TESTING_SAVED "${BUILD_TESTING}")
  set(BUILD_TESTING OFF)
  FetchContent_MakeAvailable(ogg)

  # vorbis's CMake looks for an Ogg::ogg target; make sure it exists even if
  # the ogg subproject did not define the alias itself.
  if(NOT TARGET Ogg::ogg)
    add_library(Ogg::ogg ALIAS ogg)
  endif()

  # vorbis's bundled FindOgg.cmake expects an *installed* ogg. Pre-seed its
  # cache variables with the in-tree build: the Ogg::ogg target (which vorbis
  # links against) already exists, so the found library path is never actually
  # consumed.
  set(OGG_INCLUDE_DIR "${ogg_SOURCE_DIR}/include" CACHE PATH "ogg headers" FORCE)
  set(OGG_LIBRARY "$<TARGET_FILE:ogg>" CACHE STRING "ogg library" FORCE)

  FetchContent_MakeAvailable(vorbis)
  set(BUILD_TESTING "${BUILD_TESTING_SAVED}")

  set(NINJAM_VORBIS_TARGETS "")
  if(TARGET Vorbis::vorbisenc)
    set(NINJAM_VORBIS_TARGETS Vorbis::vorbisenc)
  elseif(TARGET vorbisenc)
    set(NINJAM_VORBIS_TARGETS vorbisenc)
  else()
    message(FATAL_ERROR "vorbisenc target not found after fetching xiph/vorbis")
  endif()
  if(TARGET Vorbis::vorbis)
    list(APPEND NINJAM_VORBIS_TARGETS Vorbis::vorbis)
  elseif(TARGET vorbis)
    list(APPEND NINJAM_VORBIS_TARGETS vorbis)
  endif()
  if(TARGET Ogg::ogg)
    list(APPEND NINJAM_VORBIS_TARGETS Ogg::ogg)
  elseif(TARGET ogg)
    list(APPEND NINJAM_VORBIS_TARGETS ogg)
  endif()
endif()

find_package(Threads REQUIRED)

# ---------------------------------------------------------------------------
# ninjam_net: protocol messages + transport (shared by server and clients)
# ---------------------------------------------------------------------------
# Note: WDL/jnetlib/test.cpp and testbnc.cpp are standalone jnetlib demo
# programs and are intentionally not part of the library.
add_library(ninjam_net STATIC
  WDL/rng.cpp
  WDL/sha.cpp
  WDL/jnetlib/asyncdns.cpp
  WDL/jnetlib/connection.cpp
  WDL/jnetlib/httpget.cpp
  WDL/jnetlib/httpserv.cpp
  WDL/jnetlib/listen.cpp
  WDL/jnetlib/util.cpp
  WDL/jnetlib/webserver.cpp
  ninjam/mpb.cpp
  ninjam/netmsg.cpp
)

target_include_directories(ninjam_net PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(ninjam_net PUBLIC Threads::Threads)

if(WIN32)
  target_link_libraries(ninjam_net PUBLIC ws2_32 winmm)
endif()

if(MSVC)
  target_compile_options(ninjam_net PRIVATE /W3)
else()
  target_compile_options(ninjam_net PRIVATE -Wall)
endif()

# ---------------------------------------------------------------------------
# ninjam_core: the NJClient client core
# ---------------------------------------------------------------------------
add_library(ninjam_core STATIC
  ninjam/njclient.cpp
  ninjam/njmisc.cpp
)
if(WIN32)
  target_sources(ninjam_core PRIVATE
    WDL/win32_utf8.c
    ninjam/njmisc_win32_stubs.cpp
  )
  set_source_files_properties(WDL/win32_utf8.c PROPERTIES
    COMPILE_DEFINITIONS WDL_WIN32_UTF8_NO_UI_IMPL)
endif()
target_link_libraries(ninjam_core PUBLIC ninjam_net ${NINJAM_VORBIS_TARGETS})
if(MSVC)
  target_compile_options(ninjam_core PRIVATE /W3)
else()
  target_compile_options(ninjam_core PRIVATE -Wall)
endif()

# ---------------------------------------------------------------------------
# ninjamsrv: the server (see ninjam/server/example.cfg)
# ---------------------------------------------------------------------------
if(NINJAM_BUILD_SERVER)
  add_executable(ninjamsrv
    ninjam/server/ninjamsrv.cpp
    ninjam/server/usercon.cpp
  )
  target_link_libraries(ninjamsrv PRIVATE ninjam_net)
  if(MSVC)
    target_compile_options(ninjamsrv PRIVATE /W3)
  else()
    target_compile_options(ninjamsrv PRIVATE -Wall -Wno-reorder)
  endif()
endif()

# ---------------------------------------------------------------------------
# Subdirectories
# ---------------------------------------------------------------------------
if(NINJAM_BUILD_CLIENT)
  add_subdirectory(ninjam/imguiclient)
endif()

if(NINJAM_BUILD_TESTS)
  enable_testing()
  add_subdirectory(ninjam/tests)
endif()
