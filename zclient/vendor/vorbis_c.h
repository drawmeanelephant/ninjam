/*
 * Translate-c input for the libogg/libvorbis encoder API (src/vorbis.zig).
 *
 * Zig 0.17 removed @cImport; build.zig runs this header through a
 * std.Build.Step.TranslateC instead, so the Zig side still sees the exact
 * C declarations of the vendored trees — same structs, same prototypes —
 * generated at build time rather than committed.
 *
 * Hand-written, not downloaded; refresh-vendor.sh copies it through
 * unchanged like the shim TUs.
 */
#include <ogg/ogg.h>
#include <vorbis/codec.h>
#include <vorbis/vorbisenc.h>
