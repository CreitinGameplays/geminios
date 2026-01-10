#!/bin/bash
set -e
XTERM_VER="389"
download_and_extract "https://invisible-mirror.net/archives/xterm/xterm-$XTERM_VER.tgz" "xterm-$XTERM_VER.tgz" "xterm-$XTERM_VER"
cd "$DEP_DIR/xterm-$XTERM_VER"
export CFLAGS="--sysroot=$ROOTFS -O2 -I$ROOTFS/usr/include -I$ROOTFS/usr/include/ncursesw"
export LDFLAGS="--sysroot=$ROOTFS -L$ROOTFS/usr/lib64"
./configure --prefix=/usr --enable-wide-chars --enable-256-color --with-x --with-tty-group=tty --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
