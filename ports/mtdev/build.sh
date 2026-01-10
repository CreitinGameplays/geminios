#!/bin/bash
set -e
MTDEV_VER="1.1.6"
download_and_extract "http://bitmath.org/code/mtdev/mtdev-$MTDEV_VER.tar.bz2" "mtdev-$MTDEV_VER.tar.bz2" "mtdev-$MTDEV_VER"
cd "$DEP_DIR/mtdev-$MTDEV_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
