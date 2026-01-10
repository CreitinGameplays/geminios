#!/bin/bash
set -e
SETXKBMAP_VER="1.3.4"
download_and_extract "https://www.x.org/archive/individual/app/setxkbmap-$SETXKBMAP_VER.tar.xz" "setxkbmap-$SETXKBMAP_VER.tar.xz" "setxkbmap-$SETXKBMAP_VER"
cd "$DEP_DIR/setxkbmap-$SETXKBMAP_VER"
./configure --prefix=/usr --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
