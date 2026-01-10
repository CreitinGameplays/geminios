#!/bin/bash
set -e

LIBXDAMAGE_VER="1.1.6"
download_and_extract "https://www.x.org/archive/individual/lib/libXdamage-$LIBXDAMAGE_VER.tar.gz" "libXdamage-$LIBXDAMAGE_VER.tar.gz" "libXdamage-$LIBXDAMAGE_VER"

cd "$DEP_DIR/libXdamage-$LIBXDAMAGE_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
