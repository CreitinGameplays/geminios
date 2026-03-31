#!/bin/bash
set -e

XFSPROGS_VER="6.13.0"
download_and_extract \
    "https://mirrors.edge.kernel.org/pub/linux/utils/fs/xfs/xfsprogs/xfsprogs-$XFSPROGS_VER.tar.xz" \
    "xfsprogs-$XFSPROGS_VER.tar.xz" \
    "xfsprogs-$XFSPROGS_VER"

cd "$DEP_DIR/xfsprogs-$XFSPROGS_VER"
make distclean || true

./configure \
    --prefix=/usr \
    --bindir=/bin \
    --sbindir=/sbin \
    --libdir=/usr/lib/x86_64-linux-gnu \
    --disable-static \
    --enable-libicu=no \
    --with-systemd-unit-dir=no \
    --with-udev-rule-dir=no \
    --with-crond-dir=no \
    --host=x86_64-linux-gnu

make -j"$JOBS"
make install DESTDIR="$ROOTFS"
