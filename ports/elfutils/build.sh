#!/bin/bash
set -e

ELFUTILS_VER="0.191"
download_and_extract "https://sourceware.org/elfutils/ftp/$ELFUTILS_VER/elfutils-$ELFUTILS_VER.tar.bz2" "elfutils-$ELFUTILS_VER.tar.bz2" "elfutils-$ELFUTILS_VER"

cd "$DEP_DIR/elfutils-$ELFUTILS_VER"
./configure --prefix=/usr --libdir=/usr/lib64 \
            --disable-debuginfod --disable-libdebuginfod \
            --disable-nls --disable-werror \
            --host=x86_64-linux-gnu

make -C lib -j$JOBS
make -C libelf -j$JOBS
make -C libelf install DESTDIR="$ROOTFS"

mkdir -p "$ROOTFS/usr/lib64/pkgconfig"
if [ -f "config/libelf.pc" ]; then
    cp config/libelf.pc "$ROOTFS/usr/lib64/pkgconfig/"
elif [ -f "libelf/libelf.pc" ]; then
    cp libelf/libelf.pc "$ROOTFS/usr/lib64/pkgconfig/"
fi
