#!/bin/bash
set -e

LIBXFIXES_VER="6.0.1"
download_and_extract "https://www.x.org/archive/individual/lib/libXfixes-$LIBXFIXES_VER.tar.gz" "libXfixes-$LIBXFIXES_VER.tar.gz" "libXfixes-$LIBXFIXES_VER"

cd "$DEP_DIR/libXfixes-$LIBXFIXES_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
