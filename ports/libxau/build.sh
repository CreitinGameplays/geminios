#!/bin/bash
set -e

LIBXAU_VER="1.0.11"
download_and_extract "https://www.x.org/archive/individual/lib/libXau-$LIBXAU_VER.tar.gz" "libXau-$LIBXAU_VER.tar.gz" "libXau-$LIBXAU_VER"

cd "$DEP_DIR/libXau-$LIBXAU_VER"
./configure --prefix=/usr --sysconfdir=/etc --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
