#!/bin/bash
set -e

XCB_UTIL_KEYSYMS_VER="0.4.1"
download_and_extract "https://xcb.freedesktop.org/dist/xcb-util-keysyms-$XCB_UTIL_KEYSYMS_VER.tar.gz" "xcb-util-keysyms-$XCB_UTIL_KEYSYMS_VER.tar.gz" "xcb-util-keysyms-$XCB_UTIL_KEYSYMS_VER"

cd "$DEP_DIR/xcb-util-keysyms-$XCB_UTIL_KEYSYMS_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
