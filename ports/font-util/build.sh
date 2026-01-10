#!/bin/bash
set -e
FONT_UTIL_VER="1.4.1"
download_and_extract "https://www.x.org/archive/individual/font/font-util-$FONT_UTIL_VER.tar.xz" "font-util-$FONT_UTIL_VER.tar.xz" "font-util-$FONT_UTIL_VER"
cd "$DEP_DIR/font-util-$FONT_UTIL_VER"
./configure --prefix=/usr --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
