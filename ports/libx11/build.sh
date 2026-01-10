#!/bin/bash
set -e

LIBX11_VER="1.8.7"
download_and_extract "https://www.x.org/archive/individual/lib/libX11-$LIBX11_VER.tar.gz" "libX11-$LIBX11_VER.tar.gz" "libX11-$LIBX11_VER"

cd "$DEP_DIR/libX11-$LIBX11_VER"
./configure --prefix=/usr --sysconfdir=/etc --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
