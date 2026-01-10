#!/bin/bash
set -e

UTIL_MACROS_VER="1.20.0"
download_and_extract "https://www.x.org/archive/individual/util/util-macros-$UTIL_MACROS_VER.tar.gz" "util-macros-$UTIL_MACROS_VER.tar.gz" "util-macros-$UTIL_MACROS_VER"

cd "$DEP_DIR/util-macros-$UTIL_MACROS_VER"
./configure --prefix=/usr --host=x86_64-linux-gnu
make install DESTDIR="$ROOTFS"
