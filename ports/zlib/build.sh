#!/bin/bash
set -e

ZLIB_VER="1.3.1"
download_and_extract "https://zlib.net/fossils/zlib-$ZLIB_VER.tar.gz" "zlib-$ZLIB_VER.tar.gz" "zlib-$ZLIB_VER"

cd "$DEP_DIR/zlib-$ZLIB_VER"
CC="gcc --sysroot=$ROOTFS" ./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
