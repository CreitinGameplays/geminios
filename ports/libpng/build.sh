#!/bin/bash
set -e

LIBPNG_VER="1.6.40"
download_and_extract "https://downloads.sourceforge.net/libpng/libpng-$LIBPNG_VER.tar.xz" "libpng-$LIBPNG_VER.tar.xz" "libpng-$LIBPNG_VER"

cd "$DEP_DIR/libpng-$LIBPNG_VER"
if [ -f Makefile ]; then
    make distclean >/dev/null 2>&1 || true
fi
rm -f config.cache config.status pnglibconf.h pnglibconf.c pnglibconf.out pnglibconf.pre pnglibconf.dfn
./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
