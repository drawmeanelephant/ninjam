# NINJAM protocol fuzzer + sanitized server builds.
#
# Targets:
#   ninjam_fuzz        libFuzzer harness (ASan+UBSan+DEBUG_TIGHT_ALLOC) over the
#                      real server connection code. This is the discovery engine.
#   ninjamsrv_asan     the real server binary with ASan+UBSan (stock WDL heap).
#   ninjamsrv_asan_tight  the real server with ASan+UBSan and WDL's
#                      DEBUG_TIGHT_ALLOC (exact-size allocations, so even 1-byte
#                      overflows land in a sanitizer redzone).
#   corpus             regenerate the seed corpus (fuzz/corpus/seeds/)
#   run                one-command unattended fuzzing session
#   replay             re-run every checked-in crash repro through the harness
#                      (must exit cleanly once the fixes are in place)
#   clean
#
# DEBUG_TIGHT_ALLOC is a WDL heapbuf.h debug mode that makes WDL_HeapBuf
# allocate exactly the requested size instead of rounding up (default
# granularity 4096). It changes allocation strategy only, not behavior, and is
# what makes small heap overflows observable to ASan.
#
# Toolchain notes:
# - The sanitizer-capable compiler is resolved via `xcrun` on macOS (bare
#   clang++ may miss the SDK sysroot); plain g++/clang++ works on Linux.
# - Apple toolchains do not ship the libFuzzer runtime archive, so if
#   $(FUZZ_RUNTIME) is missing we fetch libFuzzer sources (pinned tag) and
#   build it. Override FUZZ_RUNTIME to a prebuilt libclang_rt.fuzzer_osx.a if
#   your toolchain has one.

LF_TAG = llvmorg-21.1.8
LF_DIR = $(BUILD)/libfuzzer-src
FUZZ_RUNTIME ?= $(BUILD)/libFuzzer.a

CXX := $(shell for c in "xcrun clang++" clang++ g++; do \
         if $$c -fsyntax-only -x c++ /dev/null >/dev/null 2>&1; then echo "$$c"; break; fi; done)
ifeq ($(CXX),)
$(error no working C++ compiler found)
endif

CXXFLAGS ?= -std=c++17 -g -O1 -fno-omit-frame-pointer -Wall -Wno-reorder -pthread
SAN = -fsanitize=address,undefined -fno-sanitize-recover=all
AR := $(shell command -v xcrun >/dev/null 2>&1 && echo "xcrun ar" || echo ar)

ROOT = ..
NETLIB = $(ROOT)/WDL/jnetlib
BUILD = $(ROOT)/build/fuzz

FUZZFLAGS = $(CXXFLAGS) $(SAN) -fsanitize=fuzzer-no-link -DDEBUG_TIGHT_ALLOC
FUZZLINK  = $(CXXFLAGS) $(SAN)
SRVFLAGS  = $(CXXFLAGS) $(SAN)

.PHONY: all ninjam_fuzz ninjamsrv_asan ninjamsrv_asan_tight corpus run replay clean

all: ninjam_fuzz ninjamsrv_asan ninjamsrv_asan_tight

$(BUILD):
	mkdir -p $(BUILD)

# --- libFuzzer runtime (built from pinned sources when not preinstalled) ----
$(LF_DIR):
	git clone --depth 1 --filter=blob:none --sparse --branch $(LF_TAG) \
	  https://github.com/llvm/llvm-project.git $@

$(FUZZ_RUNTIME): $(LF_DIR)
	cd $(LF_DIR) && git sparse-checkout set compiler-rt/lib/fuzzer
	mkdir -p $(BUILD)/libfuzzer
	for f in $(LF_DIR)/compiler-rt/lib/fuzzer/*.cpp; do \
	  case "$$(basename $$f)" in \
	    *Win32*|FuzzerInterceptors*|*wrapper*) continue;; \
	  esac; \
	  $(CXX) -std=c++17 -c -O2 -g -fno-exceptions -fno-rtti -stdlib=libc++ \
	    -o $(BUILD)/libfuzzer/"$$(basename $$f .cpp).o" "$$f" || exit 1; \
	done
	$(AR) rcs $@ $(BUILD)/libfuzzer/*.o

# --- fuzzer harness ---------------------------------------------------------
FUZZ_OBJS = $(BUILD)/harness.o $(BUILD)/fuzz_mpb.o $(BUILD)/fuzz_netmsg.o \
            $(BUILD)/fuzz_usercon.o $(BUILD)/fuzz_rng.o $(BUILD)/fuzz_sha.o \
            $(BUILD)/fuzz_jnl_util.o

ninjam_fuzz: $(BUILD) $(FUZZ_OBJS) $(FUZZ_RUNTIME)
	$(CXX) $(FUZZLINK) -o $(BUILD)/ninjam_fuzz $(FUZZ_OBJS) $(FUZZ_RUNTIME)

$(BUILD)/harness.o: harness.cpp
	$(CXX) $(FUZZFLAGS) -c -o $@ $<

$(BUILD)/fuzz_mpb.o: $(ROOT)/ninjam/mpb.cpp
	$(CXX) $(FUZZFLAGS) -c -o $@ $<

$(BUILD)/fuzz_netmsg.o: $(ROOT)/ninjam/netmsg.cpp
	$(CXX) $(FUZZFLAGS) -c -o $@ $<

$(BUILD)/fuzz_usercon.o: $(ROOT)/ninjam/server/usercon.cpp
	$(CXX) $(FUZZFLAGS) -c -o $@ $<

$(BUILD)/fuzz_rng.o: $(ROOT)/WDL/rng.cpp
	$(CXX) $(FUZZFLAGS) -c -o $@ $<

$(BUILD)/fuzz_sha.o: $(ROOT)/WDL/sha.cpp
	$(CXX) $(FUZZFLAGS) -c -o $@ $<

$(BUILD)/fuzz_jnl_util.o: $(NETLIB)/util.cpp
	$(CXX) $(FUZZFLAGS) -c -o $@ $<

# --- real server binaries ---------------------------------------------------
SRV_OBJS = $(NETLIB)/asyncdns.cpp $(NETLIB)/connection.cpp $(NETLIB)/listen.cpp \
           $(NETLIB)/util.cpp $(NETLIB)/httpget.cpp $(ROOT)/WDL/rng.cpp \
           $(ROOT)/WDL/sha.cpp $(ROOT)/ninjam/mpb.cpp $(ROOT)/ninjam/netmsg.cpp \
           $(ROOT)/ninjam/server/usercon.cpp $(ROOT)/ninjam/server/ninjamsrv.cpp

ninjamsrv_asan: $(BUILD) $(SRV_OBJS)
	$(CXX) $(SRVFLAGS) -o $(BUILD)/ninjamsrv_asan $(SRV_OBJS)

ninjamsrv_asan_tight: $(BUILD) $(SRV_OBJS)
	$(CXX) $(SRVFLAGS) -DDEBUG_TIGHT_ALLOC -o $(BUILD)/ninjamsrv_asan_tight $(SRV_OBJS)

# --- corpus / runs ----------------------------------------------------------
corpus: gen_corpus.py
	python3 gen_corpus.py

# Unattended session: fork mode keeps going past crashes and files each one
# under fuzz/artifacts/. Tune FUZZ_TIME as desired (default 30 min).
FUZZ_TIME ?= 1800
FUZZ_JOBS ?= 4
run: ninjam_fuzz corpus
	mkdir -p $(ROOT)/fuzz/artifacts
	$(BUILD)/ninjam_fuzz $(ROOT)/fuzz/corpus/run $(ROOT)/fuzz/corpus/seeds \
	  -dict=$(ROOT)/fuzz/ninjam.dict \
	  -fork=$(FUZZ_JOBS) -ignore_crashes=1 -max_len=8192 -rss_limit_mb=4096 \
	  -max_total_time=$(FUZZ_TIME) -artifact_prefix=$(ROOT)/fuzz/artifacts/ \
	  -print_final_stats=1

# Every checked-in repro must run through the harness cleanly (exit 0) once the
# fixes are in. Any nonzero exit means a regression.
replay: ninjam_fuzz
	@rc=0; for f in $(ROOT)/fuzz/corpus/crash-*; do \
	   [ -f "$$f" ] || { echo "no crash repros found"; exit 0; }; \
	   if $(BUILD)/ninjam_fuzz "$$f" -runs=1 >/dev/null 2>"$(BUILD)/replay_fail.log"; then \
	     echo "OK   $$f"; \
	   else \
	     echo "FAIL $$f (see $(BUILD)/replay_fail.log)"; rc=1; \
	   fi; \
	 done; exit $$rc

clean:
	rm -rf $(BUILD)
