#!/bin/bash
set -e
CAIRO_VER="1.18.0"
download_and_extract "https://cairographics.org/releases/cairo-$CAIRO_VER.tar.xz" "cairo-$CAIRO_VER.tar.xz" "cairo-$CAIRO_VER"
cd "$DEP_DIR/cairo-$CAIRO_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dtee=enabled -Dxcb=enabled -Dxlib=enabled -Dtests=disabled -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
