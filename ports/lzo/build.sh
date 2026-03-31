#!/bin/bash
set -e

LZO_VER="2.10"
download_and_extract \
    "https://www.oberhumer.com/opensource/lzo/download/lzo-$LZO_VER.tar.gz" \
    "lzo-$LZO_VER.tar.gz" \
    "lzo-$LZO_VER"

cd "$DEP_DIR/lzo-$LZO_VER"
make distclean || true

./configure \
    --prefix=/usr \
    --bindir=/bin \
    --sbindir=/sbin \
    --libdir=/usr/lib/x86_64-linux-gnu \
    --enable-shared \
    --disable-static \
    --host=x86_64-linux-gnu

make -j"$JOBS"
make install DESTDIR="$ROOTFS"
