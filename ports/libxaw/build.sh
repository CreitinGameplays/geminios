#!/bin/bash
set -e

LIBXAW_VER="1.0.15"
download_and_extract "https://www.x.org/archive/individual/lib/libXaw-$LIBXAW_VER.tar.gz" "libXaw-$LIBXAW_VER.tar.gz" "libXaw-$LIBXAW_VER"

cd "$DEP_DIR/libXaw-$LIBXAW_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
