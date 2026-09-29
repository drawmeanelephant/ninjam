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

To rebuild the trees from scratch:

```sh
curl -LO https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz
curl -LO https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz
tar xzf libogg-1.3.6.tar.gz && tar xzf libvorbis-1.3.7.tar.gz
# then keep only the files listed under "What was trimmed"
```
