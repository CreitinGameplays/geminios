#!/bin/bash
set -e
PKG_VER="2.21"
PKG_NAME="which"
SRC_URL="https://ftp.gnu.org/gnu/which/which-$PKG_VER.tar.gz"
ARCHIVE="which-$PKG_VER.tar.gz"
DIR="which-$PKG_VER"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"

./configure --prefix=/usr

make -j$JOBS
make install DESTDIR="$ROOTFS"

# Create symlink in /bin
mkdir -p "$ROOTFS/bin"
ln -sf /usr/bin/which "$ROOTFS/bin/which"
