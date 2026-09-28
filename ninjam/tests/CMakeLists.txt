add_executable(ninjam_tests
  test_core.cpp
)

target_link_libraries(ninjam_tests PRIVATE ninjam_core)

if(MSVC)
  target_compile_options(ninjam_tests PRIVATE /W3)
else()
  target_compile_options(ninjam_tests PRIVATE -Wall)
endif()

add_test(NAME ninjam_tests COMMAND ninjam_tests)

# End-to-end test: boots the real server and drives two headless clients.
if(NINJAM_BUILD_SERVER)
  add_executable(ninjam_e2e
    e2e_test.cpp
  )
  target_link_libraries(ninjam_e2e PRIVATE ninjam_core)
  if(MSVC)
    target_compile_options(ninjam_e2e PRIVATE /W3)
  else()
    target_compile_options(ninjam_e2e PRIVATE -Wall)
  endif()
  add_test(NAME ninjam_e2e COMMAND ninjam_e2e $<TARGET_FILE:ninjamsrv>)
  set_tests_properties(ninjam_e2e PROPERTIES TIMEOUT 120)
endif()

# ---------------------------------------------------------------------------
# Visual regression: renders the GUI client's UI offscreen (software
# rasterizer, no window/GPU) to PNG snapshots and compares them against the
# golden images in ninjam/tests/golden/. Run `ninjam_ui_snapshot --update` to
# (re)baseline after an intentional UI change.
# ---------------------------------------------------------------------------
if(TARGET ninjam_ui)
  FetchContent_Declare(stb
    GIT_REPOSITORY https://github.com/nothings/stb.git
    GIT_TAG 2c980bb59875b0d32144a71867fbdebb2f77cd20)
  FetchContent_MakeAvailable(stb)

  add_executable(ninjam_ui_snapshot
    ui_snapshot.cpp
  )
  target_include_directories(ninjam_ui_snapshot PRIVATE ${stb_SOURCE_DIR})
  target_link_libraries(ninjam_ui_snapshot PRIVATE ninjam_ui)
  target_compile_definitions(ninjam_ui_snapshot PRIVATE
    NINJAM_UI_GOLDEN_DIR="${CMAKE_CURRENT_SOURCE_DIR}/golden"
    NINJAM_UI_OUTDIR="${CMAKE_BINARY_DIR}/ui-snapshots")
  if(MSVC)
    target_compile_options(ninjam_ui_snapshot PRIVATE /W3)
  else()
    target_compile_options(ninjam_ui_snapshot PRIVATE -Wall)
  endif()

  foreach(sc empty mixer chat)
    add_test(NAME ui_snapshot_${sc} COMMAND ninjam_ui_snapshot ${sc})
    set_tests_properties(ui_snapshot_${sc} PROPERTIES TIMEOUT 120)
  endforeach()
endif()
