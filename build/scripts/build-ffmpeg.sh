#!/bin/bash
# Build FFmpeg static libraries for one Apple platform slice.
#
# Usage: build-ffmpeg.sh <platform-id>   (see platforms.sh for ids)
#
# Output: build/output/<platform-id>/{include,lib}
#
# Configuration policy (see PLAN.md §5):
#  - LGPL only (no --enable-gpl), decode/demux only (no encoders/muxers)
#  - --disable-autodetect for reproducible builds; SDK-provided deps enabled explicitly
#  - VideoToolbox + AudioToolbox + SecureTransport (TLS without OpenSSL)
#  - dav1d (BSD-2-Clause) for software AV1: FFmpeg's native AV1 decoder only
#    drives hardware, which most Apple devices lack (build-dav1d.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/platforms.sh"

PLATFORM="${1:?usage: build-ffmpeg.sh <platform-id>}"
platform_env "$PLATFORM"

FFMPEG_VERSION="$(python3 -c "import json;print(json.load(open('$BUILD_DIR/versions.json'))['ffmpeg']['version'])")"
TARBALL="$BUILD_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SRC_DIR="$BUILD_DIR/src/ffmpeg-${FFMPEG_VERSION}-${PLATFORM}"
PREFIX="$BUILD_DIR/output/$PLATFORM"
JOBS="$(sysctl -n hw.ncpu)"

# dav1d first: FFmpeg's configure links it through pkg-config.
"$SCRIPT_DIR/build-dav1d.sh" "$PLATFORM"
DAV1D_VERSION="$(python3 -c "import json;print(json.load(open('$BUILD_DIR/versions.json'))['dav1d']['version'])")"
DAV1D_PREFIX="$BUILD_DIR/src/dav1d-${DAV1D_VERSION}-${PLATFORM}/install"
# LIBDIR, not PATH: only this slice's dav1d may be found — never a host
# (Homebrew) copy built for another platform.
export PKG_CONFIG_LIBDIR="$DAV1D_PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH

echo "==> FFmpeg ${FFMPEG_VERSION} for ${PLATFORM} (target ${TARGET}, sdk ${SDK})"

# Fresh per-platform source tree (FFmpeg does not support out-of-tree config reuse well)
rm -rf "$SRC_DIR" && mkdir -p "$SRC_DIR"
tar -xf "$TARBALL" -C "$SRC_DIR" --strip-components=1

# Apply local patches (visionOS availability fixes, etc.)
for patch_file in "$BUILD_DIR"/patches/*.patch; do
    [ -f "$patch_file" ] || continue
    patch -p1 -d "$SRC_DIR" -s < "$patch_file"
    echo "==> applied $(basename "$patch_file")"
done

CC="$(xcrun --sdk "$SDK" -f clang)"
CFLAGS="-target $TARGET -isysroot $SYSROOT -O2 -fno-stack-check"
LDFLAGS="-target $TARGET -isysroot $SYSROOT"

cd "$SRC_DIR"
./configure \
    --prefix="$PREFIX" \
    --enable-cross-compile \
    --target-os=darwin \
    --arch="$FF_ARCH" \
    --cc="$CC" \
    --as="$CC" \
    --extra-cflags="$CFLAGS" \
    --extra-ldflags="$LDFLAGS" \
    --pkg-config=pkg-config \
    --pkg-config-flags=--static \
    --disable-autodetect \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-gpl \
    --disable-nonfree \
    --disable-avdevice \
    --disable-encoders \
    --disable-muxers \
    --disable-outdevs \
    --disable-indevs \
    --disable-xlib \
    --disable-sdl2 \
    --enable-pic \
    --enable-network \
    --enable-zlib \
    --enable-bzlib \
    --enable-iconv \
    --enable-securetransport \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    --enable-libdav1d \
    --enable-swscale \
    --enable-swresample \
    --enable-avfilter \
    > "$BUILD_DIR/configure-$PLATFORM.log" 2>&1 || {
        echo "configure failed — tail of log:"; tail -40 "$BUILD_DIR/configure-$PLATFORM.log"; exit 1; }

make -j"$JOBS" > "$BUILD_DIR/make-$PLATFORM.log" 2>&1 || {
    echo "make failed — tail of log:"; tail -40 "$BUILD_DIR/make-$PLATFORM.log"; exit 1; }
rm -rf "$PREFIX"
make install >> "$BUILD_DIR/make-$PLATFORM.log" 2>&1
# make-xcframework.sh merges every lib*.a in here into libffmpeg.a.
cp "$DAV1D_PREFIX/lib/libdav1d.a" "$PREFIX/lib/"

echo "==> Installed to $PREFIX"
ls "$PREFIX/lib"
