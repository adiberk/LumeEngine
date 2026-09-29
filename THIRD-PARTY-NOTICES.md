# Third-party notices

LumeEngine's own source code is MIT-licensed (see [`LICENSE`](LICENSE)). The engine is
useless without FFmpeg, however, and FFmpeg comes with obligations that travel with any
binary you ship. This document states exactly what is linked, under which license, and
what you have to do about it.

---

## FFmpeg — LGPL 2.1 or later

LumeEngine links **FFmpeg 9.0.1** (`libavcodec`, `libavformat`, `libavutil`,
`libavfilter`, `libswscale`, `libswresample`). The pinned version and source URL live in
[`build/versions.json`](build/versions.json); the build is performed by
[`build/scripts/build-ffmpeg.sh`](build/scripts/build-ffmpeg.sh).

- **License**: GNU Lesser General Public License, version 2.1 or later — full text in
  [`LICENSES/LGPL-2.1.txt`](LICENSES/LGPL-2.1.txt) (verbatim copy of `COPYING.LGPLv2.1`
  from the FFmpeg 9.0.1 tarball).
- **Upstream**: <https://ffmpeg.org> · <https://git.ffmpeg.org/ffmpeg.git>

### The build is LGPL, not GPL

This is a deliberate, enforced configuration, not an assumption. `build-ffmpeg.sh`
configures with `--disable-gpl --disable-nonfree`, so no GPL-only component
(`libx264`, `libx265`, `libpostproc`, the GPL filters, …) can be compiled in. FFmpeg's
own `configure` confirms it, and the line is preserved in the per-slice configure logs:

```
License: LGPL version 2.1 or later
```

The build additionally disables encoders, muxers, programs, and `avdevice` — the engine
decodes and demuxes only.

### Modified FFmpeg source

[`build/patches/0001-visionos-videotoolbox-no-opengles.patch`](build/patches/0001-visionos-videotoolbox-no-opengles.patch)
patches FFmpeg source before compilation. **That patch is a modification of an LGPL work
and is licensed under the LGPL 2.1+, not under this repository's MIT license.** It is
kept in-repo, unobfuscated, and applied by the build script, which is how the
"convey your modifications" obligation is met.

### Enabled dependencies, and their licenses

Everything except dav1d comes from the Apple SDKs. dav1d is the one library built from
source and linked statically (see [its own section](#dav1d--bsd-2-clause)):

| Component | Enabled via | License |
|---|---|---|
| VideoToolbox, AudioToolbox, SecureTransport, CoreMedia, CoreVideo | `--enable-videotoolbox --enable-audiotoolbox --enable-securetransport` | Apple system frameworks (Apple SDK license) |
| zlib | `--enable-zlib` | zlib license |
| bzip2 | `--enable-bzlib` | BSD-style (bzip2 license) |
| libiconv | `--enable-iconv` | LGPL 2.1+ (system library) |
| dav1d 1.5.4 | `--enable-libdav1d` | BSD-2-Clause (built from source, static) |

Notably **no OpenSSL** — TLS goes through SecureTransport, which keeps the build both
smaller and LGPL-clean.

`build/versions.json` also lists **libass** (ISC) with `"status": "planned"`. It is
*not* built or linked today. If you enable it, extend this file and add its license text
to [`LICENSES/`](LICENSES) — and note that libass pulls in freetype (FTL *or* GPLv2),
harfbuzz (MIT), fribidi (LGPL 2.1+), and libunibreak (zlib), which changes this table
materially.

---

## dav1d — BSD-2-Clause

LumeEngine links **dav1d 1.5.4**, VideoLAN's AV1 decoder, for software AV1 decoding.
FFmpeg's own AV1 decoder only drives hardware, and most Apple chips have no AV1
hardware decoder. The pinned version, source URL, and SHA-256 are in
[`build/versions.json`](build/versions.json); the build is performed by
[`build/scripts/build-dav1d.sh`](build/scripts/build-dav1d.sh), called for every slice by
`build-ffmpeg.sh`, and the static `libdav1d.a` is merged into `libffmpeg.a` alongside
FFmpeg's libraries.

- **License**: BSD 2-Clause — full text in
  [`LICENSES/dav1d-BSD-2-Clause.txt`](LICENSES/dav1d-BSD-2-Clause.txt) (verbatim copy of
  `COPYING` from the dav1d 1.5.4 tarball). Unmodified: no patches are applied.
- **Upstream**: <https://code.videolan.org/videolan/dav1d>

BSD-2-Clause is permissive and compatible with the LGPL build; it adds no relinking
requirement. It does add an attribution requirement for binaries (below).

---

## What this means if you ship a binary

The engine ships FFmpeg as a **static** `libffmpeg.a` inside
`FFmpeg.xcframework`, which is linked into **`LumeEngine`, a dynamic library**
(`.library(name: "LumeEngine", type: .dynamic, …)` in `Package.swift` — this is one of
several reasons that product type is not negotiable).

For an application that links LumeEngine, the LGPL's relinking requirement (LGPL 2.1
§6) is satisfied in the standard way for this arrangement:

1. **The engine that embeds FFmpeg is itself open source and MIT-licensed.** Every
   source file needed to rebuild `LumeEngine` is in this repository.
2. **The FFmpeg build is fully reproducible from this repository.** The version is
   pinned with a SHA-256 checksum, the configure flags are in the build script, and the
   only local modification is the patch named above.
3. Therefore a recipient can replace FFmpeg with their own modified version — change
   `build/versions.json` or the patch set, re-run `build/scripts/build-ffmpeg.sh` and
   `build/scripts/make-xcframework.sh`, rebuild the engine, and relink the app.

Your remaining obligations when distributing an application built on LumeEngine:

- **Say that you use FFmpeg**, and state that it is licensed under the LGPL 2.1+
  (an "Acknowledgements"/"Legal" screen is the usual place on Apple platforms).
- **Include the LGPL 2.1 license text** — `LICENSES/LGPL-2.1.txt`.
- **Point users at the FFmpeg source you built from**, including your modifications:
  the pinned upstream tarball plus this repository (or your fork of it) is sufficient.
- **Reproduce dav1d's copyright notice, conditions, and disclaimer** in your
  documentation or acknowledgements (BSD-2-Clause, clause 2) —
  `LICENSES/dav1d-BSD-2-Clause.txt` verbatim is sufficient.
- Keep the engine dynamically linked, or otherwise preserve the ability to relink.

This is not legal advice; it is a description of how this repository is set up to make
compliance straightforward.

---

## Test fixtures

The test suite generates its media fixtures locally with a host `ffmpeg` binary
([`Tests/LumeEngineCoreTests/Fixtures/generate-fixtures.sh`](Tests/LumeEngineCoreTests/Fixtures/generate-fixtures.sh)).
They are synthetic — generated from FFmpeg's own test patterns and tones — and are
gitignored rather than committed. No third-party media is redistributed by this
repository.
