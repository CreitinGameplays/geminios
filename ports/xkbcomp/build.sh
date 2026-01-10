#!/bin/bash
set -e
XKBCOMP_VER="1.4.6"
download_and_extract "https://www.x.org/archive/individual/app/xkbcomp-$XKBCOMP_VER.tar.gz" "xkbcomp-$XKBCOMP_VER.tar.gz" "xkbcomp-$XKBCOMP_VER"
cd "$DEP_DIR/xkbcomp-$XKBCOMP_VER"
./configure --prefix=/usr --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
