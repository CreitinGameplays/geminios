#!/bin/bash
set -e
NANO_VER="7.2"
download_and_extract "https://www.nano-editor.org/dist/v7/nano-$NANO_VER.tar.gz" "nano-$NANO_VER.tar.gz" "nano-$NANO_VER"
cd "$DEP_DIR/nano-$NANO_VER"
export CFLAGS="--sysroot=$ROOTFS -O2 -static"
export LDFLAGS="--sysroot=$ROOTFS -static"
./configure --prefix=/usr --enable-tiny --disable-libmagic --disable-mouse \
    --disable-help --disable-browser --disable-speller --disable-justify --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
