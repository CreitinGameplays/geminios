#!/bin/bash
set -e

F2FS_TOOLS_VER="1.16.0"
download_and_extract \
    "https://mirrors.edge.kernel.org/pub/linux/kernel/people/jaegeuk/f2fs-tools/f2fs-tools-$F2FS_TOOLS_VER.tar.gz" \
    "f2fs-tools-$F2FS_TOOLS_VER.tar.gz" \
    "f2fs-tools-$F2FS_TOOLS_VER"

cd "$DEP_DIR/f2fs-tools-$F2FS_TOOLS_VER"
make distclean || true

./configure \
    --prefix=/usr \
    --bindir=/bin \
    --sbindir=/sbin \
    --libdir=/usr/lib/x86_64-linux-gnu \
    --host=x86_64-linux-gnu

make -j"$JOBS"
make install DESTDIR="$ROOTFS"
