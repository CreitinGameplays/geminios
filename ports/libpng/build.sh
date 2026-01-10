#!/bin/bash
set -e

LIBPNG_VER="1.6.40"
download_and_extract "https://downloads.sourceforge.net/libpng/libpng-$LIBPNG_VER.tar.xz" "libpng-$LIBPNG_VER.tar.xz" "libpng-$LIBPNG_VER"

cd "$DEP_DIR/libpng-$LIBPNG_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
