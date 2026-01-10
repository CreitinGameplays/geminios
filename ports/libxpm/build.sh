#!/bin/bash
set -e

LIBXPM_VER="3.5.17"
download_and_extract "https://www.x.org/archive/individual/lib/libXpm-$LIBXPM_VER.tar.gz" "libXpm-$LIBXPM_VER.tar.gz" "libXpm-$LIBXPM_VER"

cd "$DEP_DIR/libXpm-$LIBXPM_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
