#!/bin/bash
set -e

UTIL_LINUX_VER="2.39.3"
download_and_extract "https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/v2.39/util-linux-$UTIL_LINUX_VER.tar.xz" "util-linux-$UTIL_LINUX_VER.tar.xz" "util-linux-$UTIL_LINUX_VER"

cd "$DEP_DIR/util-linux-$UTIL_LINUX_VER"
make clean || true
./configure --prefix=/usr --libdir=/usr/lib64 \
    --bindir=/bin \
    --sbindir=/sbin \
    --enable-libuuid \
    --enable-libblkid \
    --enable-libmount \
    --enable-kill \
    --enable-mount \
    --enable-umount \
    --enable-fdisk \
    --enable-cfdisk \
    --enable-sfdisk \
    --enable-partx \
    --enable-cal \
    --enable-whereis \
    --enable-rename \
    --enable-hexdump \
    --enable-wall \
    --enable-write \
    --enable-mesg \
    --disable-makeinstall-chown \
    --disable-makeinstall-setuid \
    --disable-selinux \
    --without-systemd \
    --without-udev \
    --without-python \
    --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
