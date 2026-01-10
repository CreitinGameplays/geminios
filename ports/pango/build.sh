#!/bin/bash
set -e
PANGO_VER="1.50.14"
download_and_extract "https://download.gnome.org/sources/pango/1.50/pango-$PANGO_VER.tar.xz" "pango-$PANGO_VER.tar.xz" "pango-$PANGO_VER"
cd "$DEP_DIR/pango-$PANGO_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dintrospection=disabled -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
