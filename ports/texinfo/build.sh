#!/bin/bash
set -e

PKG_NAME="texinfo"
PKG_VER="7.1"
SRC_URL="https://ftp.gnu.org/gnu/texinfo/texinfo-$PKG_VER.tar.xz"
SRC_DIR="texinfo-$PKG_VER"

# Download and Extract
download_and_extract "$SRC_URL" "$SRC_DIR.tar.xz" "$SRC_DIR"

rm -rf build
mkdir -p build
cd build

# Configure
if [ ! -f "Makefile" ]; then
    "$DEP_DIR/$SRC_DIR/configure" \
        --prefix=/usr \
        --disable-nls \
        --with-sysroot="$ROOTFS" \
        MAKEINFO=true
fi

# Build
make -j$JOBS MAKEINFO=true

# Install
make install DESTDIR="$ROOTFS" MAKEINFO=true

# Cleanup
rm -rf "$ROOTFS/usr/share/info"
rm -rf "$ROOTFS/usr/share/man"

