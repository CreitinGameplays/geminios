#!/bin/bash
set -e
LIBDRM_VER="2.4.120"
download_and_extract "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz" "libdrm-$LIBDRM_VER.tar.xz" "libdrm-$LIBDRM_VER"
cd "$DEP_DIR/libdrm-$LIBDRM_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Dudev=true -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled -Dvmwgfx=enabled -Dtests=false -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
