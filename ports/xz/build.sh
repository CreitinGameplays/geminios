#!/bin/bash
set -e

XZ_VER="5.6.4"
download_and_extract "https://tukaani.org/xz/xz-$XZ_VER.tar.xz" "xz-$XZ_VER.tar.xz" "xz-$XZ_VER"

cd "$DEP_DIR/xz-$XZ_VER"

./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu

make -j$JOBS
make install DESTDIR="$ROOTFS"
