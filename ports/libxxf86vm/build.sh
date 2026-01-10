#!/bin/bash
set -e

LIBXXF86VM_VER="1.1.5"
download_and_extract "https://www.x.org/archive/individual/lib/libXxf86vm-$LIBXXF86VM_VER.tar.gz" "libXxf86vm-$LIBXXF86VM_VER.tar.gz" "libXxf86vm-$LIBXXF86VM_VER"

cd "$DEP_DIR/libXxf86vm-$LIBXXF86VM_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
