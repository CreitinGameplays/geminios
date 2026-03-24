#!/bin/bash
set -e

GETTEXT_VER="0.22.4"
download_and_extract "https://ftp.gnu.org/gnu/gettext/gettext-$GETTEXT_VER.tar.xz" "gettext-$GETTEXT_VER.tar.xz" "gettext-$GETTEXT_VER"

cd "$DEP_DIR/gettext-$GETTEXT_VER"
if [ -f "Makefile" ]; then
    make distclean >/dev/null 2>&1 || true
fi
rm -f config.cache config.status
./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu \
    --disable-static --enable-shared --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
