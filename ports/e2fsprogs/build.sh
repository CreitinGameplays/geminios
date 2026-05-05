#!/bin/bash
set -e
PKG_VER="1.47.0"
PKG_NAME="e2fsprogs"
SRC_URL="https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$PKG_VER/e2fsprogs-$PKG_VER.tar.xz"
ARCHIVE="e2fsprogs-$PKG_VER.tar.xz"
DIR="e2fsprogs-$PKG_VER"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"

rm -rf build
mkdir -p build
cd build

../configure --prefix=/usr \
             --bindir=/bin \
             --sbindir=/sbin \
             --libdir=/usr/lib/x86_64-linux-gnu \
             --enable-elf-shlibs \
             --disable-uuidd \
             --disable-fsck \
             --disable-libblkid \
             --disable-libuuid

# e2fsprogs libblkid/uuid are often older than util-linux, so we disable them and use util-linux's.

make -j$JOBS
make install DESTDIR="$ROOTFS"
make install-libs DESTDIR="$ROOTFS"

# e2fsprogs now installs into the canonical Debian multiarch library tree.
