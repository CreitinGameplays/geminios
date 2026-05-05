#!/bin/bash
set -e

LIBXPM_VER="3.5.17"
download_and_extract "https://www.x.org/archive/individual/lib/libXpm-$LIBXPM_VER.tar.gz" "libXpm-$LIBXPM_VER.tar.gz" "libXpm-$LIBXPM_VER"

cd "$DEP_DIR/libXpm-$LIBXPM_VER"
./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --disable-static --host=x86_64-linux-gnu
# sxpm is an optional Xt-based viewer utility. In this cross-build it can
# resolve against host-side session-management libraries via libXt, while the
# libXpm library itself builds cleanly without it.
sed -i 's/\bsxpm\b//g; s/  */ /g' Makefile
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
