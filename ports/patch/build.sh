#!/bin/bash
set -e
PKG_VER="2.7.6"
PKG_NAME="patch"
SRC_URL="https://ftp.gnu.org/gnu/patch/patch-$PKG_VER.tar.xz"
ARCHIVE="patch-$PKG_VER.tar.xz"
DIR="patch-$PKG_VER"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"

./configure --prefix=/usr

make -j$JOBS
make install DESTDIR="$ROOTFS"
