#!/bin/bash
set -e
LIBPCIACCESS_VER="0.17"
download_and_extract "https://www.x.org/archive/individual/lib/libpciaccess-$LIBPCIACCESS_VER.tar.xz" "libpciaccess-$LIBPCIACCESS_VER.tar.xz" "libpciaccess-$LIBPCIACCESS_VER"
cd "$DEP_DIR/libpciaccess-$LIBPCIACCESS_VER"
./configure --prefix=/usr --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
