#!/bin/bash
set -e

LIBXML2_VER="2.12.4"
download_and_extract "https://download.gnome.org/sources/libxml2/2.12/libxml2-$LIBXML2_VER.tar.xz" "libxml2-$LIBXML2_VER.tar.xz" "libxml2-$LIBXML2_VER"

cd "$DEP_DIR/libxml2-$LIBXML2_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc \
    --disable-static --without-python --without-icu --with-zlib --host=x86_64-linux-gnu

make -j$JOBS
make install DESTDIR="$ROOTFS"
