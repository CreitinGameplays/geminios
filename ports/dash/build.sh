#!/bin/bash
set -e

PKG_VER="0.5.12"
PKG_NAME="dash"
SRC_URL="https://deb.debian.org/debian/pool/main/d/dash/dash_${PKG_VER}.orig.tar.gz"
ARCHIVE="dash-${PKG_VER}.orig.tar.gz"
DIR="dash-${PKG_VER}"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"

./configure --prefix=/usr \
            --bindir=/usr/bin \
            --mandir=/usr/share/man \
            --disable-nls \
            --host=x86_64-linux-gnu \
            LDFLAGS="$LDFLAGS -static"

make -j$JOBS
make install DESTDIR="$ROOTFS"

mkdir -p "$ROOTFS/bin"
if ! rootfs_dirs_alias "$ROOTFS/usr/bin" "$ROOTFS/bin"; then
    ln -sfn ../usr/bin/dash "$ROOTFS/bin/dash"
fi
