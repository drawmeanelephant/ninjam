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

## Local deltas

`stb_vorbis.c` carries marked local security deltas on top of the pinned
upstream commit (each hunk is tagged in-file; `refresh-vendor.sh` applies
`patches/*.patch` after the SHA-256-verified download, and `--check` compares
the committed tree against upstream + patches). They make stb_vorbis's error
paths safe for wire-hostile input, which is a hard requirement for a client
that decodes whatever a server puts on the wire:

1. `setup_malloc` / `setup_temp_malloc` refuse non-positive sizes. Sizes are
   wire-driven `int` products, so a hostile stream can wrap one negative
   (e.g. a vendor/comment length near 2^31); the malloc-backed mode happened
   to survive that (`malloc((size_t)negative)` fails), the caller-buffer mode
   did not.
2. The Vorbis comment count is bounded by `INT_MAX/8` and by the remaining
   stream bytes before the slot array is allocated, so its `sizeof(char*) *
   count` cannot truncate below the true size.
3. When a comment-string allocation fails mid-list, the count is shrunk to
   the entries that were actually initialized.
4. `vorbis_deinit` no longer dereferences `comment_list` when the slot-array
   allocation failed (the count is already set by then).
5. The codebook header's `entries * dimensions` product is bounded by
   `INT_MAX/sizeof(float)` before anything is allocated with it. The type-1
   pre-expansion sizes its multiplicands array through an `int`, and a
   spec-legal header can claim a product whose byte size wraps to a small
   positive value — reachable from a ~2 KB stream via the ordered-run length
   encoding — after which the expansion loop marches 4 GB of writes past the
   array.

All five reproduce on stb v1.22. Found by the wire-hostile audit of the
downstream fart-app client (#63/#64/#66 there); the regression tests live
downstream, where the decoder runs in caller-buffer mode.

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
