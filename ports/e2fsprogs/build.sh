#!/bin/bash
set -e
PKG_VER="1.47.0"
PKG_NAME="e2fsprogs"
SRC_URL="https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$PKG_VER/e2fsprogs-$PKG_VER.tar.xz"
ARCHIVE="e2fsprogs-$PKG_VER.tar.xz"
DIR="e2fsprogs-$PKG_VER"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"

mkdir -p build
cd build

../configure --prefix=/usr \
             --bindir=/bin \
             --sbindir=/sbin \
             --libdir=/usr/lib64 \
             --enable-elf-shlibs \
             --disable-uuidd \
             --disable-fsck

# e2fsprogs libblkid/uuid are often older than util-linux, so we disable them and use util-linux's.

make -j$JOBS
make install DESTDIR="$ROOTFS"

# Install libs to /lib64/ as well if needed? usually install puts them in /usr/lib64 as configured.
