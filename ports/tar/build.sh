#!/bin/bash
set -e
PKG_VER="1.35"
PKG_NAME="tar"
SRC_URL="https://ftp.gnu.org/gnu/tar/tar-$PKG_VER.tar.xz"
ARCHIVE="tar-$PKG_VER.tar.xz"
DIR="tar-$PKG_VER"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"

FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr

make -j$JOBS
make install DESTDIR="$ROOTFS"
