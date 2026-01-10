#!/bin/bash
set -e

LIBSM_VER="1.2.4"
download_and_extract "https://www.x.org/archive/individual/lib/libSM-$LIBSM_VER.tar.gz" "libSM-$LIBSM_VER.tar.gz" "libSM-$LIBSM_VER"

cd "$DEP_DIR/libSM-$LIBSM_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
