#!/bin/bash
set -e

LIBXCB_VER="1.16"
download_and_extract "https://www.x.org/archive/individual/lib/libxcb-$LIBXCB_VER.tar.gz" "libxcb-$LIBXCB_VER.tar.gz" "libxcb-$LIBXCB_VER"

cd "$DEP_DIR/libxcb-$LIBXCB_VER"
./configure --prefix=/usr --sysconfdir=/etc --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
