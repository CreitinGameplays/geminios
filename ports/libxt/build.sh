#!/bin/bash
set -e

LIBXT_VER="1.3.0"
download_and_extract "https://www.x.org/archive/individual/lib/libXt-$LIBXT_VER.tar.gz" "libXt-$LIBXT_VER.tar.gz" "libXt-$LIBXT_VER"

cd "$DEP_DIR/libXt-$LIBXT_VER"
./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
