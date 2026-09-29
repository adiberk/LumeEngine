#!/bin/bash
# Build dav1d (software AV1 decoder, BSD-2-Clause) as a static library for one
# Apple platform slice. Called by build-ffmpeg.sh before FFmpeg's configure,
# which links it through --enable-libdav1d.
#
# Usage: build-dav1d.sh <platform-id>   (see platforms.sh for ids)
#
# Output: build/src/dav1d-<version>-<platform>/install/{include,lib}
#
# Why it exists: FFmpeg's native AV1 decoder only drives hardware, and only
# Apple's newest chips decode AV1 in hardware. Without dav1d, AV1 plays as a
# black picture on everything else — the current Apple TV 4K included.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/platforms.sh"

PLATFORM="${1:?usage: build-dav1d.sh <platform-id>}"
platform_env "$PLATFORM"

for tool in meson ninja; do
    command -v "$tool" >/dev/null || { echo "$tool is required (brew install meson ninja)" >&2; exit 1; }
done

DAV1D_VERSION="$(python3 -c "import json;print(json.load(open('$BUILD_DIR/versions.json'))['dav1d']['version'])")"
TARBALL="$BUILD_DIR/dav1d-${DAV1D_VERSION}.tar.xz"
SRC_DIR="$BUILD_DIR/src/dav1d-${DAV1D_VERSION}-${PLATFORM}"
PREFIX="$SRC_DIR/install"

echo "==> dav1d ${DAV1D_VERSION} for ${PLATFORM}"

rm -rf "$SRC_DIR" && mkdir -p "$SRC_DIR"
tar -xf "$TARBALL" -C "$SRC_DIR" --strip-components=1

case "$FF_ARCH" in
    arm64)  CPU_FAMILY=aarch64 ;;
    x86_64) CPU_FAMILY=x86_64
            # dav1d's x86 assembly is NASM; without it the Intel slices would be
            # C-only and several times slower.
            command -v nasm >/dev/null || { echo "nasm is required for x86_64 slices (brew install nasm)" >&2; exit 1; } ;;
esac

# `system` stays 'darwin' for every slice: dav1d's own build checks recognise
# only darwin/ios/tvos, and visionOS would otherwise miss the Mach-O symbol
# prefix its assembly needs. `subsystem` carries the actual platform for meson.
case "$SDK" in
    macosx)                     SUBSYSTEM=macos ;;
    iphoneos|iphonesimulator)   SUBSYSTEM=ios ;;
    appletvos|appletvsimulator) SUBSYSTEM=tvos ;;
    xros|xrsimulator)           SUBSYSTEM=visionos ;;
esac

CC="$(xcrun --sdk "$SDK" -f clang)"
AR="$(xcrun --sdk "$SDK" -f ar)"
STRIP="$(xcrun --sdk "$SDK" -f strip)"
CROSS_FILE="$SRC_DIR/cross.ini"
cat > "$CROSS_FILE" <<EOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
nasm = '$(command -v nasm || echo nasm)'

[built-in options]
c_args = ['-target', '$TARGET', '-isysroot', '$SYSROOT', '-fno-stack-check']
c_link_args = ['-target', '$TARGET', '-isysroot', '$SYSROOT']

[host_machine]
system = 'darwin'
subsystem = '$SUBSYSTEM'
cpu_family = '$CPU_FAMILY'
cpu = '$FF_ARCH'
endian = 'little'
EOF

meson setup "$SRC_DIR/build" "$SRC_DIR" \
    --cross-file "$CROSS_FILE" \
    --prefix "$PREFIX" \
    --libdir lib \
    --buildtype release \
    --default-library static \
    -Denable_tools=false \
    -Denable_tests=false \
    -Denable_examples=false \
    > "$BUILD_DIR/configure-dav1d-$PLATFORM.log" 2>&1 || {
        echo "meson setup failed — tail of log:"; tail -40 "$BUILD_DIR/configure-dav1d-$PLATFORM.log"; exit 1; }

ninja -C "$SRC_DIR/build" install > "$BUILD_DIR/make-dav1d-$PLATFORM.log" 2>&1 || {
    echo "ninja failed — tail of log:"; tail -40 "$BUILD_DIR/make-dav1d-$PLATFORM.log"; exit 1; }

echo "==> Installed to $PREFIX"
