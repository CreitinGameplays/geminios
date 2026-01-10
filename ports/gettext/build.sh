#!/bin/bash
set -e

GETTEXT_VER="0.22.4"
download_and_extract "https://ftp.gnu.org/gnu/gettext/gettext-$GETTEXT_VER.tar.xz" "gettext-$GETTEXT_VER.tar.xz" "gettext-$GETTEXT_VER"

cd "$DEP_DIR/gettext-$GETTEXT_VER"
if [ ! -f "Makefile" ]; then
    ./configure --prefix=/usr --disable-static --enable-shared --host=x86_64-linux-gnu
fi
make -j$JOBS
make install DESTDIR="$ROOTFS"
