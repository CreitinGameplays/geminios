#!/bin/bash
set -e
LIBEPOXY_VER="1.5.10"
download_and_extract "https://download.gnome.org/sources/libepoxy/1.5/libepoxy-$LIBEPOXY_VER.tar.xz" "libepoxy-$LIBEPOXY_VER.tar.xz" "libepoxy-$LIBEPOXY_VER"
cd "$DEP_DIR/libepoxy-$LIBEPOXY_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Dtests=false -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
