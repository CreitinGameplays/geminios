#!/bin/bash
set -e
EUDEV_VER="3.2.14"
download_and_extract "https://github.com/eudev-project/eudev/releases/download/v$EUDEV_VER/eudev-$EUDEV_VER.tar.gz" "eudev-$EUDEV_VER.tar.gz" "eudev-$EUDEV_VER"
cd "$DEP_DIR/eudev-$EUDEV_VER"
./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --sysconfdir=/etc --disable-static --enable-selinux --disable-introspection --disable-blkid --disable-kmod --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"

if [ -f "$ROOTFS/usr/lib/x86_64-linux-gnu/libudev.la" ]; then
    sed -i "s|^dependency_libs=.*$|dependency_libs=''|" "$ROOTFS/usr/lib/x86_64-linux-gnu/libudev.la"
fi
