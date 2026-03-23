#!/bin/bash
set -e

UTIL_LINUX_VER="2.39.3"
download_and_extract "https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/v2.39/util-linux-$UTIL_LINUX_VER.tar.xz" "util-linux-$UTIL_LINUX_VER.tar.xz" "util-linux-$UTIL_LINUX_VER"

cd "$DEP_DIR/util-linux-$UTIL_LINUX_VER"
make distclean || true
export CC="gcc"
export LDFLAGS="--sysroot=$ROOTFS"
./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu \
    --bindir=/bin \
    --sbindir=/sbin \
    --enable-libuuid \
    --enable-libblkid \
    --enable-libmount \
    --enable-kill \
    --enable-mount \
    --enable-partx \
    --enable-cal \
    --enable-whereis \
    --enable-rename \
    --enable-wall \
    --enable-write \
    --enable-mesg \
    --disable-chfn-chsh \
    --disable-login \
    --disable-su \
    --disable-runuser \
    --disable-makeinstall-chown \
    --disable-makeinstall-setuid \
    --without-selinux \
    --without-systemd \
    --without-udev \
    --without-python
make -j$JOBS
make install DESTDIR="$ROOTFS"

# GeminiOS ships its own login implementation from ginit.
rm -f "$ROOTFS/bin/login"

# GeminiOS ships its own login/getty flow from ginit, so keep util-linux
# account-management frontends out of the image for now.
rm -f "$ROOTFS/bin/su" \
      "$ROOTFS/sbin/runuser" \
      "$ROOTFS/usr/bin/chfn" \
      "$ROOTFS/usr/bin/chsh"
