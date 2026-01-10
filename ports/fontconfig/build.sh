#!/bin/bash
set -e

FONTCONFIG_VER="2.15.0"
download_and_extract "https://www.freedesktop.org/software/fontconfig/release/fontconfig-$FONTCONFIG_VER.tar.xz" "fontconfig-$FONTCONFIG_VER.tar.xz" "fontconfig-$FONTCONFIG_VER"

cd "$DEP_DIR/fontconfig-$FONTCONFIG_VER"
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static --disable-docs
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
