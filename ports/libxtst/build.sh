#!/bin/bash
set -e

LIBXTST_VER="1.2.4"
download_and_extract "https://www.x.org/archive/individual/lib/libXtst-$LIBXTST_VER.tar.gz" "libXtst-$LIBXTST_VER.tar.gz" "libXtst-$LIBXTST_VER"

cd "$DEP_DIR/libXtst-$LIBXTST_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
