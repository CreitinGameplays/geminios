#!/bin/bash
set -e
LIBXFONT2_VER="2.0.6"
download_and_extract "https://www.x.org/archive/individual/lib/libXfont2-$LIBXFONT2_VER.tar.gz" "libXfont2-$LIBXFONT2_VER.tar.gz" "libXfont2-$LIBXFONT2_VER"
cd "$DEP_DIR/libXfont2-$LIBXFONT2_VER"
./configure --prefix=/usr --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
