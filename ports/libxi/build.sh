#!/bin/bash
set -e

LIBXI_VER="1.8.1"
download_and_extract "https://www.x.org/archive/individual/lib/libXi-$LIBXI_VER.tar.gz" "libXi-$LIBXI_VER.tar.gz" "libXi-$LIBXI_VER"

cd "$DEP_DIR/libXi-$LIBXI_VER"
./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
