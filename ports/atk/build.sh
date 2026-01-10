#!/bin/bash
set -e
ATK_VER="2.38.0"
download_and_extract "https://download.gnome.org/sources/atk/2.38/atk-$ATK_VER.tar.xz" "atk-$ATK_VER.tar.xz" "atk-$ATK_VER"
cd "$DEP_DIR/atk-$ATK_VER"

rm -rf build

# Ensure g-ir-scanner can find the giscanner python module in rootfs
export PYTHONPATH="$ROOTFS/usr/lib64/gobject-introspection:$PYTHONPATH"

meson setup build --prefix=/usr --libdir=lib64 -Dintrospection=false -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install