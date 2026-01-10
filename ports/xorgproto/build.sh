#!/bin/bash
set -e

XORGPROTO_VER="2023.2"
download_and_extract "https://www.x.org/archive/individual/proto/xorgproto-$XORGPROTO_VER.tar.gz" "xorgproto-$XORGPROTO_VER.tar.gz" "xorgproto-$XORGPROTO_VER"

cd "$DEP_DIR/xorgproto-$XORGPROTO_VER"
./configure --prefix=/usr --host=x86_64-linux-gnu
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
