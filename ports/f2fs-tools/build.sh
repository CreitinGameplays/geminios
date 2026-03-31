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

./configure \
    --prefix=/usr \
    --bindir=/bin \
    --sbindir=/sbin \
    --libdir=/usr/lib/x86_64-linux-gnu \
    --host=x86_64-linux-gnu

make -j"$JOBS"
make install DESTDIR="$ROOTFS"
