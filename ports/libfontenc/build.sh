#!/bin/bash
set -e
LIBFONTENC_VER="1.1.7"
download_and_extract "https://www.x.org/archive/individual/lib/libfontenc-$LIBFONTENC_VER.tar.gz" "libfontenc-$LIBFONTENC_VER.tar.gz" "libfontenc-$LIBFONTENC_VER"
cd "$DEP_DIR/libfontenc-$LIBFONTENC_VER"
./configure --prefix=/usr --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
