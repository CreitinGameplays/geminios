#!/bin/bash
set -e
LIBEVDEV_VER="1.13.1"
download_and_extract "https://www.freedesktop.org/software/libevdev/libevdev-$LIBEVDEV_VER.tar.xz" "libevdev-$LIBEVDEV_VER.tar.xz" "libevdev-$LIBEVDEV_VER"
cd "$DEP_DIR/libevdev-$LIBEVDEV_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
