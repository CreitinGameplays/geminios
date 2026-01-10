#!/bin/bash
set -e
LIBGLVND_VER="1.7.0"
download_and_extract "https://gitlab.freedesktop.org/glvnd/libglvnd/-/archive/v$LIBGLVND_VER/libglvnd-v$LIBGLVND_VER.tar.gz" "libglvnd-$LIBGLVND_VER.tar.gz" "libglvnd-v$LIBGLVND_VER"
cd "$DEP_DIR/libglvnd-v$LIBGLVND_VER"

rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Dglx=enabled -Degl=true -Dgles1=true -Dgles2=true -Dtls=true -Dheaders=true -Dentrypoint-patching=enabled -Dwerror=false

ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
