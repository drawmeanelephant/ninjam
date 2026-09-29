#!/usr/bin/env bash
# Reproduce zclient/vendor/ exactly: pinned downloads, SHA-256 verification,
# and the trim rule documented in vendor/README.md.
#
#   ./vendor/refresh-vendor.sh            # rewrite vendor/ in place
#   ./vendor/refresh-vendor.sh --check    # regenerate to a temp dir and diff
#                                          # against the committed tree; exits
#                                          # non-zero on any drift
#
# --check is the one to run in CI or before a release: it answers "is the
# committed vendor tree still exactly what upstream ships?", without touching
# the working tree.
#
# To move a dependency forward: change its version and SHA-256 below, run the
# script, rebuild, run the tests and the demo. Nothing else encodes the trim
# rule, so this file is the only thing that has to stay correct.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# ---- pins -------------------------------------------------------------------
OGG_VER=1.3.6
OGG_SHA=83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638
OGG_URL=https://downloads.xiph.org/releases/ogg/libogg-$OGG_VER.tar.gz

VORBIS_VER=1.3.7
VORBIS_SHA=0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab
VORBIS_URL=https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS_VER.tar.gz

# miniaudio is a single header; 0.11.25 is what src/audio.zig was written
# against. Objects are transparent in this version (see the header), so an
# API change here is a compile error rather than silent misbehaviour.
MINIAUDIO_VER=0.11.25
MINIAUDIO_SHA=ac7af4de748b7e26b777f37e01cee313a308a7296a3eb080e2906b320cc55c89
MINIAUDIO_URL=https://raw.githubusercontent.com/mackron/miniaudio/$MINIAUDIO_VER/miniaudio.h

# stb has no releases; pin the commit.
STB_COMMIT=2c980bb59875b0d32144a71867fbdebb2f77cd20
STB_SHA=4c7cb2ff1f7011e9d67950446b7eb9ca044f2e464d76bfbb0b84dd2e23e65636
STB_URL=https://raw.githubusercontent.com/nothings/stb/$STB_COMMIT/stb_vorbis.c

# The trim rule. Everything not listed is dropped: build systems, docs, tests,
# platform ports and IDE projects are not compiled by zclient's build.zig.
KEEP_DOCS=(AUTHORS CHANGES COPYING README.md)
KEEP_SUFFIXES=(.c .h)

sha256_of() { # file
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

fetch() { # url sha dest
  local url=$1 want=$2 dest=$3 got
  curl -fsSL --retry 3 --max-time 120 -o "$dest" "$url"
  got=$(sha256_of "$dest")
  if [ "$got" != "$want" ]; then
    echo "checksum mismatch for $url" >&2
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    exit 1
  fi
}

trim_tree() { # root
  local root=$1
  find "$root" -type f \( -name 'Makefile.am' -o -name 'Makefile.in' \
      -o -name 'CMakeLists.txt' -o -name '*.vcproj' -o -name '*.vcxproj' \
      -o -name '*.sln' -o -name '*.in' -o -name 'configure' -o -name 'configure.ac' \
      -o -name 'aclocal.m4' -o -name '*.m4' -o -name '*.spec' -o -name '*.sh' \
      -o -name 'config.guess' -o -name 'config.sub' -o -name 'depcomp' \
      -o -name 'compile' -o -name 'missing' -o -name 'install-sh' \
      -o -name 'ltmain.sh' -o -name '.gitignore' -o -name '*.txt' \) -delete
  find "$root" -type d \( -name doc -o -name m4 -o -name test -o -name win32 \
      -o -name macosx -o -name symbian -o -name examples -o -name cmake \
      -o -name debian -o -name vq -o -name ci -o -name '.deps' -o -name '.libs' \
      -o -name '.github' \) -prune -exec rm -rf {} +
}

# libogg ships ogg/os_types.h with per-platform typedefs for Windows, macOS,
# Haiku, BeOS, OS/2, DJGPP, PS2, Symbian and TMS320C6X -- and a fallthrough
# branch for everything else that includes <ogg/config_types.h>. That header is
# NOT in the tarball; upstream generates it, autotools from config_types.h.in
# and CMake via configure_file(). Linux needs it, macOS never reaches it (its
# branch at os_types.h:71 matches first), so a build that only ever runs on
# macOS will not notice it is missing.
#
# So generate it exactly the way libogg's own CMakeLists.txt does: the same
# integer types, stdint-based, with no configure-time probing.
generate_config_types() { # root
  local root=$1
  sed -e 's|@INCLUDE_INTTYPES_H@|0|' \
      -e 's|@INCLUDE_STDINT_H@|1|' \
      -e 's|@INCLUDE_SYS_TYPES_H@|0|' \
      -e 's|@SIZE16@|int16_t|' -e 's|@USIZE16@|uint16_t|' \
      -e 's|@SIZE32@|int32_t|' -e 's|@USIZE32@|uint32_t|' \
      -e 's|@SIZE64@|int64_t|' -e 's|@USIZE64@|uint64_t|' \
      "$root/include/ogg/config_types.h.in" > "$root/include/ogg/config_types.h"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/vendor"
mkdir -p "$OUT"

echo "== libogg $OGG_VER =="
fetch "$OGG_URL" "$OGG_SHA" "$WORK/libogg.tar.gz"
tar xzf "$WORK/libogg.tar.gz" -C "$WORK"
mv "$WORK/libogg-$OGG_VER" "$OUT/libogg"
generate_config_types "$OUT/libogg"
trim_tree "$OUT/libogg"

echo "== libvorbis $VORBIS_VER =="
fetch "$VORBIS_URL" "$VORBIS_SHA" "$WORK/libvorbis.tar.gz"
tar xzf "$WORK/libvorbis.tar.gz" -C "$WORK"
mv "$WORK/libvorbis-$VORBIS_VER" "$OUT/libvorbis"
trim_tree "$OUT/libvorbis"

echo "== miniaudio $MINIAUDIO_VER =="
fetch "$MINIAUDIO_URL" "$MINIAUDIO_SHA" "$OUT/miniaudio.h"

echo "== stb_vorbis @ $STB_COMMIT =="
fetch "$STB_URL" "$STB_SHA" "$OUT/stb_vorbis.c"

# Hand-written, not downloaded: the shim TU and the stb/miniaudio glue.
echo "== local sources =="
for f in miniaudio_impl.c stb_vorbis_impl.c; do
  [ -f "$HERE/$f" ] || { echo "missing local source $f" >&2; exit 1; }
  cp "$HERE/$f" "$OUT/$f"
done

# README.md and refresh-vendor.sh live in vendor/ and are not downloaded.
cp "$HERE/README.md" "$OUT/README.md"
cp "$HERE/refresh-vendor.sh" "$OUT/refresh-vendor.sh"

if [ "$CHECK_ONLY" = "1" ]; then
  echo "== checking committed tree against regenerated =="
  if diff -r -q "$HERE" "$OUT"; then
    echo "vendor tree matches upstream pins"
    exit 0
  fi
  echo "DRIFT: vendor/ differs from what upstream ships (see diff above)" >&2
  exit 1
fi

echo "== writing $HERE =="
# Replace only the downloaded trees and files; leave anything else alone.
rm -rf "$HERE/libogg" "$HERE/libvorbis"
cp -R "$OUT/libogg" "$OUT/libvorbis" "$HERE/"
cp "$OUT/miniaudio.h" "$OUT/stb_vorbis.c" "$HERE/"
echo "done. Now: cd .. && zig build test && bash demo/run_demo.sh"
