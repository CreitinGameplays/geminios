#!/bin/bash
set -e

LIBXRANDR_VER="1.5.4"
download_and_extract "https://www.x.org/archive/individual/lib/libXrandr-$LIBXRANDR_VER.tar.gz" "libXrandr-$LIBXRANDR_VER.tar.gz" "libXrandr-$LIBXRANDR_VER"

cd "$DEP_DIR/libXrandr-$LIBXRANDR_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
