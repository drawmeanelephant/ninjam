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

# ---------------------------------------------------------------------------
# Fuzz-crash regression: replays every checked-in fuzzer crash repro
# (fuzz/corpus/crash-*.bin) through the real server connection code, plus
# API-level parser checks. Built with ASan+UBSan and WDL's DEBUG_TIGHT_ALLOC
# (exact-size heap allocations) so a reverted parse-bounds fix aborts on its
# repro and the test fails. Without sanitizer support the API checks still run.
# ---------------------------------------------------------------------------
if(NOT WIN32)
  include(CheckCXXCompilerFlag)
  set(CMAKE_REQUIRED_LINK_OPTIONS "-fsanitize=address")
  check_cxx_compiler_flag("-fsanitize=address" NINJAM_HAS_ASAN)
  set(CMAKE_REQUIRED_LINK_OPTIONS "-fsanitize=undefined -fno-sanitize-recover=all")
  check_cxx_compiler_flag("-fsanitize=undefined -fno-sanitize-recover=all" NINJAM_HAS_UBSAN)
  unset(CMAKE_REQUIRED_LINK_OPTIONS)

  add_executable(ninjam_fuzz_regression
    ${CMAKE_CURRENT_SOURCE_DIR}/../../fuzz/harness.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../../fuzz/replay_main.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../../fuzz/regression_checks.cpp
    ../mpb.cpp
    ../netmsg.cpp
    ../netcond.cpp
    ../server/usercon.cpp
    ../../WDL/rng.cpp
    ../../WDL/sha.cpp
    ../../WDL/jnetlib/util.cpp
  )
  if(NINJAM_HAS_ASAN)
    target_compile_options(ninjam_fuzz_regression PRIVATE -fsanitize=address)
    target_link_options(ninjam_fuzz_regression PRIVATE -fsanitize=address)
  endif()
  if(NINJAM_HAS_UBSAN)
    target_compile_options(ninjam_fuzz_regression PRIVATE -fsanitize=undefined -fno-sanitize-recover=all)
    target_link_options(ninjam_fuzz_regression PRIVATE -fsanitize=undefined -fno-sanitize-recover=all)
  endif()
  if(NOT NINJAM_HAS_ASAN)
    message(STATUS "sanitizers unavailable: ninjam_fuzz_regression will run API checks only")
  endif()
  target_compile_definitions(ninjam_fuzz_regression PRIVATE DEBUG_TIGHT_ALLOC)
  if(MSVC)
    target_compile_options(ninjam_fuzz_regression PRIVATE /W3)
  else()
    target_compile_options(ninjam_fuzz_regression PRIVATE -Wall -Wno-reorder)
  endif()
  add_test(NAME ninjam_fuzz_regression COMMAND ninjam_fuzz_regression
    "${CMAKE_CURRENT_SOURCE_DIR}/../../fuzz/corpus")
endif()

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

  # Interval-model experiment. Not part of ctest: the interesting runs are
  # minutes long and are driven by tools/run_interval_lab.sh, which writes
  # its own results to REPORT.md and results/.
  add_executable(ninjam_interval_lab
    interval_lab.cpp
  )
  target_link_libraries(ninjam_interval_lab PRIVATE ninjam_core)
  if(MSVC)
    target_compile_options(ninjam_interval_lab PRIVATE /W3)
  else()
    target_compile_options(ninjam_interval_lab PRIVATE -Wall)
  endif()
endif()

# Detector self-test: no server, no network, just the matched filter against
# a synthetic stream. Keeps the measurement instrument itself honest.
add_executable(ninjam_probe_selftest
  probe_selftest.cpp
)
if(MSVC)
  target_compile_options(ninjam_probe_selftest PRIVATE /W3)
else()
  target_compile_options(ninjam_probe_selftest PRIVATE -Wall)
endif()
add_test(NAME ninjam_probe_selftest COMMAND ninjam_probe_selftest)

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
