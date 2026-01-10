#!/bin/bash
set -e

LIBICE_VER="1.1.1"
download_and_extract "https://www.x.org/archive/individual/lib/libICE-$LIBICE_VER.tar.gz" "libICE-$LIBICE_VER.tar.gz" "libICE-$LIBICE_VER"

cd "$DEP_DIR/libICE-$LIBICE_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
