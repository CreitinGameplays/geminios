#!/bin/bash
set -e

LIBJPEG_TURBO_VER="3.0.1"
download_and_extract "https://downloads.sourceforge.net/libjpeg-turbo/libjpeg-turbo-$LIBJPEG_TURBO_VER.tar.gz" "libjpeg-turbo-$LIBJPEG_TURBO_VER.tar.gz" "libjpeg-turbo-$LIBJPEG_TURBO_VER"

cd "$DEP_DIR/libjpeg-turbo-$LIBJPEG_TURBO_VER"
rm -rf build
mkdir -p build && cd build
rm -rf "$ROOTFS$DEP_DIR/libjpeg-turbo-$LIBJPEG_TURBO_VER"
cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib/x86_64-linux-gnu -DENABLE_STATIC=FALSE ..
make -j$JOBS
make install DESTDIR="$ROOTFS"
