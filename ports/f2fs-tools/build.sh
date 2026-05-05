#!/bin/bash
set -euo pipefail

F2FS_TOOLS_VER="1.16.0"
download_and_extract \
    "https://sources.voidlinux.org/f2fs-tools-$F2FS_TOOLS_VER/f2fs-tools-$F2FS_TOOLS_VER.tar.gz" \
    "f2fs-tools-$F2FS_TOOLS_VER.tar.gz" \
    "f2fs-tools-$F2FS_TOOLS_VER"

cd "$DEP_DIR/f2fs-tools-$F2FS_TOOLS_VER"

if [ -f Makefile ]; then
    make distclean || true
fi

if [ ! -x ./configure ]; then
    sh ./autogen.sh
fi

configure_args=(
    --prefix=/usr
    --bindir=/bin
    --sbindir=/sbin
    --libdir=/usr/lib/x86_64-linux-gnu
    --host=x86_64-linux-gnu
)

if [ ! -f "$ROOTFS/usr/include/lzo/lzo1x.h" ] || \
   { [ ! -e "$ROOTFS/usr/lib/x86_64-linux-gnu/liblzo2.so" ] && [ ! -e "$ROOTFS/usr/lib/x86_64-linux-gnu/liblzo2.so.2" ]; }; then
    echo "Disabling LZO2 support for f2fs-tools; staged liblzo2 headers/runtime are incomplete."
    configure_args+=(--without-lzo2)
fi

if [ ! -f "$ROOTFS/usr/include/lz4.h" ] || \
   { [ ! -e "$ROOTFS/usr/lib/x86_64-linux-gnu/liblz4.so" ] && [ ! -e "$ROOTFS/usr/lib/x86_64-linux-gnu/liblz4.so.1" ]; }; then
    echo "Disabling LZ4 support for f2fs-tools; staged liblz4 headers/runtime are incomplete."
    configure_args+=(--without-lz4)
fi

./configure "${configure_args[@]}"

make -j"$JOBS"
make install DESTDIR="$ROOTFS"
