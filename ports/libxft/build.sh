#!/bin/bash
set -e

LIBXFT_VER="2.3.8"
download_and_extract "https://www.x.org/archive/individual/lib/libXft-$LIBXFT_VER.tar.gz" "libXft-$LIBXFT_VER.tar.gz" "libXft-$LIBXFT_VER"

cd "$DEP_DIR/libXft-$LIBXFT_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
