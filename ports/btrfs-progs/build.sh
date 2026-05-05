#!/bin/bash
set -e

BTRFS_PROGS_VER="6.13"
download_and_extract \
    "https://www.kernel.org/pub//linux/kernel/people/kdave/btrfs-progs/btrfs-progs-v$BTRFS_PROGS_VER.tar.xz" \
    "btrfs-progs-v$BTRFS_PROGS_VER.tar.xz" \
    "btrfs-progs-v$BTRFS_PROGS_VER"

cd "$DEP_DIR/btrfs-progs-v$BTRFS_PROGS_VER"
make distclean || true

configure_args=(
    --prefix=/usr
    --bindir=/bin
    --sbindir=/sbin
    --libdir=/usr/lib/x86_64-linux-gnu
    --disable-documentation
    --disable-python
    --host=x86_64-linux-gnu
)

if [ -f "$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig/libudev.pc" ] && \
   [ -e "$ROOTFS/usr/lib/x86_64-linux-gnu/libudev.so" -o -e "$ROOTFS/usr/lib/x86_64-linux-gnu/libudev.so.1" ]; then
    echo "Using staged libudev support for btrfs-progs."
else
    echo "Disabling libudev support for btrfs-progs; staged libudev is not available."
    configure_args+=(--disable-libudev)
fi

./configure "${configure_args[@]}"

make -j"$JOBS"
make install DESTDIR="$ROOTFS"
