#!/bin/bash
set -e
XF86_INPUT_EVDEV_VER="2.10.6"
download_and_extract "https://www.x.org/archive/individual/driver/xf86-input-evdev-$XF86_INPUT_EVDEV_VER.tar.gz" "xf86-input-evdev-$XF86_INPUT_EVDEV_VER.tar.gz" "xf86-input-evdev-$XF86_INPUT_EVDEV_VER"
cd "$DEP_DIR/xf86-input-evdev-$XF86_INPUT_EVDEV_VER"
./configure --prefix=/usr --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
