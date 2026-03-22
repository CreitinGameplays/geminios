#!/bin/bash
set -e

LIBINPUT_VER="1.26.2"
download_and_extract \
    "https://gitlab.freedesktop.org/libinput/libinput/-/releases/$LIBINPUT_VER/downloads/libinput-$LIBINPUT_VER.tar.xz" \
    "libinput-$LIBINPUT_VER.tar.xz" \
    "libinput-$LIBINPUT_VER"

cd "$DEP_DIR/libinput-$LIBINPUT_VER"
rm -rf build
meson setup build \
    --prefix=/usr \
    --libdir=lib64 \
    -Ddefault_library=shared \
    -Ddocumentation=false \
    -Dtests=false \
    -Ddebug-gui=false \
    -Dlibwacom=false \
    -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
