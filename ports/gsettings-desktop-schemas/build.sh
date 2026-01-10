#!/bin/bash
set -e
GSETTINGS_SCHEMAS_VER="42.0"
download_and_extract "https://download.gnome.org/sources/gsettings-desktop-schemas/42/gsettings-desktop-schemas-$GSETTINGS_SCHEMAS_VER.tar.xz" "gsettings-desktop-schemas-$GSETTINGS_SCHEMAS_VER.tar.xz" "gsettings-desktop-schemas-$GSETTINGS_SCHEMAS_VER"
cd "$DEP_DIR/gsettings-desktop-schemas-$GSETTINGS_SCHEMAS_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Dintrospection=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
