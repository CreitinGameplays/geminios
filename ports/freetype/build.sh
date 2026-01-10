#!/bin/bash
set -e

FREETYPE_VER="2.13.2"
download_and_extract "https://download-mirror.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.xz" "freetype-$FREETYPE_VER.tar.xz" "freetype-$FREETYPE_VER"

cd "$DEP_DIR/freetype-$FREETYPE_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static \
    --without-harfbuzz --without-bzip2 --without-brotli --with-png --with-zlib
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
