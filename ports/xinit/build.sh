#!/bin/bash
set -e
XINIT_VER="1.4.2"
download_and_extract "https://www.x.org/archive/individual/app/xinit-$XINIT_VER.tar.gz" "xinit-$XINIT_VER.tar.gz" "xinit-$XINIT_VER"
cd "$DEP_DIR/xinit-$XINIT_VER"
./configure --prefix=/usr --with-xinitdir=/etc/X11/xinit --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
ln -sf xinit "$ROOTFS/usr/bin/startx"
