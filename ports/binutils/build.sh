#!/bin/bash
set -e

PKG_NAME="binutils"
PKG_VER="2.42"
SRC_URL="https://ftp.gnu.org/gnu/binutils/binutils-$PKG_VER.tar.xz"
SRC_DIR="binutils-$PKG_VER"

# Download and Extract
download_and_extract "$SRC_URL" "$SRC_DIR.tar.xz" "$SRC_DIR"

rm -rf build
mkdir -p build
cd build


# Configure
# We match the system configuration: x86_64, installing to /usr
if [ ! -f "Makefile" ]; then
    "$DEP_DIR/$SRC_DIR/configure" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --disable-nls \
        --disable-werror \
        --with-system-zlib \
        --enable-gold \
        --enable-ld=default \
        --enable-plugins \
        --enable-shared \
        --disable-gdb \
        --disable-gdbserver \
        --disable-gprofng \
        --with-debuginfod=no \
        --with-sysroot="$ROOTFS" \
        --with-build-sysroot="$ROOTFS" \
        MAKEINFO=true
fi

# Build
make -j$JOBS MAKEINFO=true

# Install
make install DESTDIR="$ROOTFS" MAKEINFO=true

# Cleanup unwanted files if necessary (docs, info, etc can be kept or stripped)
rm -rf "$ROOTFS/usr/share/info"
rm -rf "$ROOTFS/usr/share/man"
