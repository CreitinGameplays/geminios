#!/bin/bash
set -e

BTRFS_PROGS_VER="6.13"
download_and_extract \
    "https://mirrors.edge.kernel.org/pub/linux/kernel/people/kdave/btrfs-progs/btrfs-progs-v$BTRFS_PROGS_VER.tar.xz" \
    "btrfs-progs-v$BTRFS_PROGS_VER.tar.xz" \
    "btrfs-progs-v$BTRFS_PROGS_VER"

cd "$DEP_DIR/btrfs-progs-v$BTRFS_PROGS_VER"
make distclean || true

./configure \
    --prefix=/usr \
    --bindir=/bin \
    --sbindir=/sbin \
    --libdir=/usr/lib/x86_64-linux-gnu \
    --host=x86_64-linux-gnu

make -j"$JOBS"
make install DESTDIR="$ROOTFS"
