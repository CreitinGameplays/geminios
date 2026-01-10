#!/bin/bash
set -e

XTRANS_VER="1.5.0"
download_and_extract "https://www.x.org/archive/individual/lib/xtrans-$XTRANS_VER.tar.gz" "xtrans-$XTRANS_VER.tar.gz" "xtrans-$XTRANS_VER"

cd "$DEP_DIR/xtrans-$XTRANS_VER"
./configure --prefix=/usr --host=x86_64-linux-gnu
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
