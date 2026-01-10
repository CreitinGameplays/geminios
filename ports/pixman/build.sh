#!/bin/bash
set -e

PIXMAN_VER="0.42.2"
download_and_extract "https://www.cairographics.org/releases/pixman-$PIXMAN_VER.tar.gz" "pixman-$PIXMAN_VER.tar.gz" "pixman-$PIXMAN_VER"

cd "$DEP_DIR/pixman-$PIXMAN_VER"
./configure --prefix=/usr --disable-static --disable-gtk --disable-libpng --disable-openmp
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
