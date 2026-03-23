#!/bin/bash
set -e

JSON_GLIB_VER="1.8.0"
download_and_extract \
    "https://download.gnome.org/sources/json-glib/1.8/json-glib-$JSON_GLIB_VER.tar.xz" \
    "json-glib-$JSON_GLIB_VER.tar.xz" \
    "json-glib-$JSON_GLIB_VER"

cd "$DEP_DIR/json-glib-$JSON_GLIB_VER"
rm -rf build
meson setup build \
    --prefix=/usr \
    --libdir=lib/x86_64-linux-gnu \
    -Ddefault_library=shared \
    -Dgtk_doc=disabled \
    -Dman=false \
    -Dintrospection=disabled \
    -Dtests=false \
    -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
