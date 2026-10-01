# Vendored dependencies

Third-party source, vendored directly: no package manager, no submodules, no
ecosystem. Each dependency is either a single file or a source-only tree.

| Path | Upstream | Version | License | Used for |
| --- | --- | --- | --- | --- |
| `stb_vorbis.c` | https://github.com/nothings/stb | public domain (Unlicense) / MIT | see file header | Vorbis decoding of peer streams |
| `libogg/` | https://xiph.org/ogg/ | 1.3.6 | BSD-3-Clause (`libogg/COPYING`) | Ogg container (encode path) |
| `libvorbis/` | https://xiph.org/vorbis/ | 1.3.7 (2020-07-04) | BSD-3-Clause (`libvorbis/COPYING`) | Vorbis encoding of the local channel |
| `miniaudio.h` | https://github.com/mackron/miniaudio | 0.11.25 | public domain / MIT-0 | live audio device (Phase B) |
| `miniaudio_impl.c` | this repository | — | same as miniaudio | the single C TU that compiles the header, behind a small shim |

`libvorbis` is 1.3.7 rather than 1.3.6 because that is what this repository's
own CMake `FetchContent` pulls in for the reference client, so zclient and the
reference client link the same encoder.

## What was trimmed

The Xiph trees ship as autotools/CMake/MSVC tarballs: ~329k lines of which
about 65k are C sources and headers. zclient compiles 25 files from those trees
via `build.zig`, so the trees were reduced to exactly what the build needs and
nothing else:

* kept — `AUTHORS`, `CHANGES`, `COPYING`, `README.md`, `include/**`, `lib/**`,
  `src/**` (`.c` and `.h`)
* dropped — `configure*`, `aclocal.m4`, `m4/`, `libtool`, `Makefile.am/.in`,
  `CMakeLists.txt`, `*.pc.in`, `*.spec*`, `win32/`, `macosx/`, `symbian/`,
  `debian/`, `doc/`, `test/`, `examples/`, `vq/`, `cmake/`, IDE project files

Nothing in the kept set is generated at build time: `libvorbis/lib/books/` and
`libvorbis/lib/modes/` are the codebook/residue tables that `vq/` would
otherwise generate, and they are committed upstream, so they stay. That is where
most of the remaining size is (1.3 MB of tables out of 2.4 MB).

To rebuild the trees from scratch, use the script rather than doing it by hand
— it is the only place the trim rule lives:

```sh
./refresh-vendor.sh            # rewrite vendor/ from the pinned downloads
./refresh-vendor.sh --check    # regenerate to a temp dir and diff against the
                               # committed tree; non-zero exit on any drift
```

`miniaudio_impl.c` and `stb_vorbis_impl.c` are hand-written (the shim TUs);
the script copies them through unchanged and will refuse to run if either is
missing.
The audio-shim regression executable lives in `tests/audio_shim_test.c`, not
the downloaded vendor tree. It uses only miniaudio's null backend and checks
playback-only operation, device selection, resource lifetime, and signed errors.

`--check` runs in CI, and in `demo/run_demo.sh`. It answers "is `vendor/` still
exactly what upstream ships?" without touching the working tree, so an accidental
edit to a vendored file fails the build instead of sitting there until the next
security bump.

To move a dependency forward: change its version and SHA-256 at the top of
`refresh-vendor.sh`, run the script, rebuild, run the tests and the demo.

### One generated header

`libogg/include/ogg/config_types.h` is **not** in the upstream tarball. Upstream
generates it — autotools from `config_types.h.in`, or CMake via
`configure_file()` — and `refresh-vendor.sh` does the same substitution with the
same integer types.

It is needed because `ogg/os_types.h` has hand-written typedefs for Windows,
macOS, Haiku, BeOS, OS/2, DJGPP, PS2, Symbian and TMS320C6X, and a fallthrough
`#else` for everything else that includes `<ogg/config_types.h>`. **macOS matches
its own branch first and never reaches the `#else`**, so a project that only ever
builds on macOS will not notice the header is missing — and the first Linux
build will fail with `'ogg/config_types.h' file not found`. If you bump libogg,
check that this header is still being generated.
