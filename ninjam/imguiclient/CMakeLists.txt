# NINJAM GUI client — Dear ImGui + GLFW + OpenGL3, miniaudio for audio I/O.
# All three dependencies are fetched at configure time.

set(GLFW_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GLFW_INSTALL OFF CACHE BOOL "" FORCE)

FetchContent_Declare(glfw
  GIT_REPOSITORY https://github.com/glfw/glfw.git
  GIT_TAG 3.5.1
  GIT_SHALLOW TRUE)
FetchContent_Declare(imgui
  GIT_REPOSITORY https://github.com/ocornut/imgui.git
  GIT_TAG v1.92.9
  GIT_SHALLOW TRUE)
FetchContent_Declare(miniaudio
  GIT_REPOSITORY https://github.com/mackron/miniaudio.git
  GIT_TAG 0.11.25
  GIT_SHALLOW TRUE)
FetchContent_MakeAvailable(glfw imgui miniaudio)

# --- Dear ImGui with GLFW + OpenGL3 backends -------------------------------
add_library(imgui_glfw_gl3 STATIC
  ${imgui_SOURCE_DIR}/imgui.cpp
  ${imgui_SOURCE_DIR}/imgui_draw.cpp
  ${imgui_SOURCE_DIR}/imgui_tables.cpp
  ${imgui_SOURCE_DIR}/imgui_widgets.cpp
  ${imgui_SOURCE_DIR}/backends/imgui_impl_glfw.cpp
  ${imgui_SOURCE_DIR}/backends/imgui_impl_opengl3.cpp
  ${imgui_SOURCE_DIR}/misc/cpp/imgui_stdlib.cpp
)
target_include_directories(imgui_glfw_gl3 PUBLIC
  ${imgui_SOURCE_DIR}
  ${imgui_SOURCE_DIR}/backends
  ${imgui_SOURCE_DIR}/misc/cpp)
target_link_libraries(imgui_glfw_gl3 PUBLIC glfw)

# --- miniaudio (single translation unit) ----------------------------------
add_library(miniaudio_impl STATIC miniaudio_impl.c)
target_include_directories(miniaudio_impl PUBLIC ${miniaudio_SOURCE_DIR})
find_package(Threads REQUIRED)
target_link_libraries(miniaudio_impl PUBLIC Threads::Threads ${CMAKE_DL_LIBS})
if(UNIX AND NOT APPLE)
  target_link_libraries(miniaudio_impl PUBLIC m)
elseif(APPLE)
  target_link_libraries(miniaudio_impl PUBLIC
    "-framework CoreFoundation"
    "-framework CoreAudio"
    "-framework AudioToolbox")
elseif(WIN32)
  target_link_libraries(miniaudio_impl PUBLIC winmm ole32 uuid avrt)
endif()

# --- shared UI layer -------------------------------------------------------
# ui.cpp has no backend dependencies; it is also rendered offscreen by the
# visual-regression harness (ninjam/tests/ui_snapshot.cpp).
add_library(ninjam_ui STATIC ui.cpp)
target_include_directories(ninjam_ui PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(ninjam_ui PUBLIC ninjam_core imgui_glfw_gl3)
if(MSVC)
  target_compile_options(ninjam_ui PRIVATE /W3)
else()
  target_compile_options(ninjam_ui PRIVATE -Wall)
endif()

# --- the client ------------------------------------------------------------
find_package(OpenGL REQUIRED)

add_executable(ninjam-client
  main.cpp
  audio_engine.cpp
)

target_link_libraries(ninjam-client PRIVATE
  ninjam_ui
  ninjam_core
  imgui_glfw_gl3
  miniaudio_impl
  OpenGL::GL)

if(MSVC)
  target_compile_options(ninjam-client PRIVATE /W3)
else()
  target_compile_options(ninjam-client PRIVATE -Wall)
endif()
