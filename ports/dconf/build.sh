#!/bin/bash
set -e

DCONF_VER="0.40.0"
download_and_extract \
    "https://download.gnome.org/sources/dconf/0.40/dconf-$DCONF_VER.tar.xz" \
    "dconf-$DCONF_VER.tar.xz" \
    "dconf-$DCONF_VER"

cd "$DEP_DIR/dconf-$DCONF_VER"
rm -rf build
meson setup build \
    --prefix=/usr \
    --libdir=lib/x86_64-linux-gnu \
    -Ddefault_library=shared \
    -Dman=false \
    -Dbash_completion=false \
    -Dgtk_doc=false \
    -Dvapi=false \
    -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
