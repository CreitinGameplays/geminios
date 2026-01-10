#!/bin/bash
set -e

LIBTIFF_VER="4.6.0"
download_and_extract "https://download.osgeo.org/libtiff/tiff-$LIBTIFF_VER.tar.gz" "tiff-$LIBTIFF_VER.tar.gz" "tiff-$LIBTIFF_VER"

cd "$DEP_DIR/tiff-$LIBTIFF_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
