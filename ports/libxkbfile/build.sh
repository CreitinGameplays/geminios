#!/bin/bash
set -e

LIBXKBFILE_VER="1.1.2"
download_and_extract "https://www.x.org/archive/individual/lib/libxkbfile-$LIBXKBFILE_VER.tar.gz" "libxkbfile-$LIBXKBFILE_VER.tar.gz" "libxkbfile-$LIBXKBFILE_VER"

cd "$DEP_DIR/libxkbfile-$LIBXKBFILE_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
