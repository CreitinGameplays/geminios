#!/bin/bash
set -e

LIBPTHREAD_STUBS_VER="0.5"
download_and_extract "https://xcb.freedesktop.org/dist/libpthread-stubs-$LIBPTHREAD_STUBS_VER.tar.gz" "libpthread-stubs-$LIBPTHREAD_STUBS_VER.tar.gz" "libpthread-stubs-$LIBPTHREAD_STUBS_VER"

cd "$DEP_DIR/libpthread-stubs-$LIBPTHREAD_STUBS_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --host=x86_64-linux-gnu
make install DESTDIR="$ROOTFS"
