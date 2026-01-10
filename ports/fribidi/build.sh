#!/bin/bash
set -e
FRIBIDI_VER="1.0.13"
download_and_extract "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VER/fribidi-$FRIBIDI_VER.tar.xz" "fribidi-$FRIBIDI_VER.tar.xz" "fribidi-$FRIBIDI_VER"
cd "$DEP_DIR/fribidi-$FRIBIDI_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Ddocs=false -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
