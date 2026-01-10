#!/bin/bash
set -e

LIBXEXT_VER="1.3.5"
download_and_extract "https://www.x.org/archive/individual/lib/libXext-$LIBXEXT_VER.tar.gz" "libXext-$LIBXEXT_VER.tar.gz" "libXext-$LIBXEXT_VER"

cd "$DEP_DIR/libXext-$LIBXEXT_VER"
./configure --prefix=/usr --sysconfdir=/etc --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
