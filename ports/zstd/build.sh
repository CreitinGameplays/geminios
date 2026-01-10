#!/bin/bash
set -e

ZSTD_VER="1.5.5"
download_and_extract "https://github.com/facebook/zstd/releases/download/v$ZSTD_VER/zstd-$ZSTD_VER.tar.gz" "zstd-$ZSTD_VER.tar.gz" "zstd-$ZSTD_VER"

cd "$DEP_DIR/zstd-$ZSTD_VER"
make -j$JOBS PREFIX=/usr LIBDIR=/usr/lib64
make install DESTDIR="$ROOTFS" PREFIX=/usr LIBDIR=/usr/lib64
