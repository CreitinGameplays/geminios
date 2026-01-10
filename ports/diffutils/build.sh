#!/bin/bash
set -e
PKG_VER="3.10"
PKG_NAME="diffutils"
SRC_URL="https://ftp.gnu.org/gnu/diffutils/diffutils-$PKG_VER.tar.xz"
ARCHIVE="diffutils-$PKG_VER.tar.xz"
DIR="diffutils-$PKG_VER"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"

./configure --prefix=/usr

make -j$JOBS
make install DESTDIR="$ROOTFS"
