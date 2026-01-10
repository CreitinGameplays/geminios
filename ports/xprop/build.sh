#!/bin/bash
set -e
XPROP_VER="1.2.6"
download_and_extract "https://www.x.org/archive/individual/app/xprop-$XPROP_VER.tar.gz" "xprop-$XPROP_VER.tar.gz" "xprop-$XPROP_VER"
cd "$DEP_DIR/xprop-$XPROP_VER"
./configure --prefix=/usr --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
