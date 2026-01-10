#!/bin/bash
set -e

LIBXCURSOR_VER="1.2.1"
download_and_extract "https://www.x.org/archive/individual/lib/libXcursor-$LIBXCURSOR_VER.tar.gz" "libXcursor-$LIBXCURSOR_VER.tar.gz" "libXcursor-$LIBXCURSOR_VER"

cd "$DEP_DIR/libXcursor-$LIBXCURSOR_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
