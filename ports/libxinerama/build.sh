#!/bin/bash
set -e

LIBXINERAMA_VER="1.1.5"
download_and_extract "https://www.x.org/archive/individual/lib/libXinerama-$LIBXINERAMA_VER.tar.gz" "libXinerama-$LIBXINERAMA_VER.tar.gz" "libXinerama-$LIBXINERAMA_VER"

cd "$DEP_DIR/libXinerama-$LIBXINERAMA_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
