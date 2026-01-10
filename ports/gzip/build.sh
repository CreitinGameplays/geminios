#!/bin/bash
set -e
PKG_VER="1.13"
PKG_NAME="gzip"
SRC_URL="https://ftp.gnu.org/gnu/gzip/gzip-$PKG_VER.tar.xz"
ARCHIVE="gzip-$PKG_VER.tar.xz"
DIR="gzip-$PKG_VER"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"

./configure --prefix=/usr

make -j$JOBS
make install DESTDIR="$ROOTFS"

# Move gzip to /bin as it's often needed early
mkdir -p "$ROOTFS/bin"
mv -v "$ROOTFS/usr/bin/gzip" "$ROOTFS/bin/gzip"
