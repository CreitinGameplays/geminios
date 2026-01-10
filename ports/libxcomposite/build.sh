#!/bin/bash
set -e

LIBXCOMPOSITE_VER="0.4.6"
download_and_extract "https://www.x.org/archive/individual/lib/libXcomposite-$LIBXCOMPOSITE_VER.tar.gz" "libXcomposite-$LIBXCOMPOSITE_VER.tar.gz" "libXcomposite-$LIBXCOMPOSITE_VER"

cd "$DEP_DIR/libXcomposite-$LIBXCOMPOSITE_VER"
./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
