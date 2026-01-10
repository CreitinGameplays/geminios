#!/bin/bash
set -e

PKG_CONFIG_VER="0.29.2"
download_and_extract "https://pkg-config.freedesktop.org/releases/pkg-config-$PKG_CONFIG_VER.tar.gz" "pkg-config-$PKG_CONFIG_VER.tar.gz" "pkg-config-$PKG_CONFIG_VER"

cd "$DEP_DIR/pkg-config-$PKG_CONFIG_VER"
if [ ! -f "Makefile" ]; then
    ./configure --prefix=/usr --with-internal-glib --host=x86_64-linux-gnu
fi
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
