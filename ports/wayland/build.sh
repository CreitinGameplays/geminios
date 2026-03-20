#!/bin/bash
set -e
WAYLAND_VER="1.22.0"
download_and_extract "https://gitlab.freedesktop.org/wayland/wayland/-/releases/$WAYLAND_VER/downloads/wayland-$WAYLAND_VER.tar.xz" "wayland-$WAYLAND_VER.tar.xz" "wayland-$WAYLAND_VER"
cd "$DEP_DIR/wayland-$WAYLAND_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Ddocumentation=false -Ddtd_validation=false -Dtests=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
