#!/bin/bash
set -e
WAYLAND_VER="1.22.0"
download_and_extract "https://gitlab.freedesktop.org/wayland/wayland/-/archive/$WAYLAND_VER/wayland-$WAYLAND_VER.tar.gz" "wayland-$WAYLAND_VER.tar.gz" "wayland-$WAYLAND_VER"
cd "$DEP_DIR/wayland-$WAYLAND_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib/x86_64-linux-gnu -Ddocumentation=false -Ddtd_validation=false -Dtests=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install

for pc in wayland-client.pc wayland-cursor.pc wayland-egl.pc wayland-server.pc; do
    if [ ! -f "$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig/$pc" ]; then
        echo "ERROR: Wayland build is missing $pc."
        exit 1
    fi
done

if [ ! -x "$ROOTFS/usr/bin/wayland-scanner" ]; then
    echo "ERROR: Wayland build is missing wayland-scanner."
    exit 1
fi
