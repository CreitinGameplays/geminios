#!/bin/bash
set -euo pipefail

DOSFSTOOLS_VER="4.2"
download_and_extract \
    "https://sources.voidlinux.org/dosfstools-$DOSFSTOOLS_VER/dosfstools-$DOSFSTOOLS_VER.tar.gz" \
    "dosfstools-$DOSFSTOOLS_VER.tar.gz" \
    "dosfstools-$DOSFSTOOLS_VER"

cd "$DEP_DIR/dosfstools-$DOSFSTOOLS_VER"

if [ -f Makefile ]; then
    make distclean || true
fi

./configure \
    --prefix=/usr \
    --bindir=/bin \
    --sbindir=/sbin \
    --host=x86_64-linux-gnu

make -j"$JOBS"
make install DESTDIR="$ROOTFS"

mkdir -p "$ROOTFS/usr/sbin"
ln -sfn mkfs.fat "$ROOTFS/usr/sbin/mkfs.vfat"
ln -sfn fsck.fat "$ROOTFS/usr/sbin/fsck.vfat"
