#!/bin/bash
set -e
LIBXRES_VER="1.2.2"
download_and_extract "https://www.x.org/releases/individual/lib/libXres-$LIBXRES_VER.tar.xz" "libXres-$LIBXRES_VER.tar.xz" "libXres-$LIBXRES_VER"
cd "$DEP_DIR/libXres-$LIBXRES_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc --localstatedir=/var --disable-static
make -j$JOBS
make DESTDIR="$ROOTFS" install
