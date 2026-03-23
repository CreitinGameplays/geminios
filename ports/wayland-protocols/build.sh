#!/bin/bash
set -e
WAYLAND_PROTOCOLS_VER="1.36"
download_and_extract "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/$WAYLAND_PROTOCOLS_VER/wayland-protocols-$WAYLAND_PROTOCOLS_VER.tar.gz" "wayland-protocols-$WAYLAND_PROTOCOLS_VER.tar.gz" "wayland-protocols-$WAYLAND_PROTOCOLS_VER"
cd "$DEP_DIR/wayland-protocols-$WAYLAND_PROTOCOLS_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib/x86_64-linux-gnu -Dtests=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
