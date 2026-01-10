#!/bin/bash
set -e

LIBXMU_VER="1.1.4"
download_and_extract "https://www.x.org/archive/individual/lib/libXmu-$LIBXMU_VER.tar.gz" "libXmu-$LIBXMU_VER.tar.gz" "libXmu-$LIBXMU_VER"

cd "$DEP_DIR/libXmu-$LIBXMU_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
