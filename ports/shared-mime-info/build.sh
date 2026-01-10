#!/bin/bash
set -e
SHARED_MIME_INFO_VER="2.4"
download_and_extract "https://gitlab.freedesktop.org/xdg/shared-mime-info/-/archive/$SHARED_MIME_INFO_VER/shared-mime-info-$SHARED_MIME_INFO_VER.tar.gz" "shared-mime-info-$SHARED_MIME_INFO_VER.tar.gz" "shared-mime-info-$SHARED_MIME_INFO_VER"
cd "$DEP_DIR/shared-mime-info-$SHARED_MIME_INFO_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Dupdate-mimedb=true -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
