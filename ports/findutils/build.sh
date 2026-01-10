#!/bin/bash
set -e
PKG_VER="4.9.0"
PKG_NAME="findutils"
SRC_URL="https://ftp.gnu.org/gnu/findutils/findutils-$PKG_VER.tar.xz"
ARCHIVE="findutils-$PKG_VER.tar.xz"
DIR="findutils-$PKG_VER"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"

./configure --prefix=/usr --localstatedir=/var/lib/locate

make -j$JOBS
make install DESTDIR="$ROOTFS"

mkdir -p "$ROOTFS/bin"
mv -v "$ROOTFS/usr/bin/find" "$ROOTFS/bin/find"
