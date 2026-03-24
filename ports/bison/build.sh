#!/bin/bash
set -e

BISON_VER="3.8.2"
download_and_extract "https://ftp.gnu.org/gnu/bison/bison-$BISON_VER.tar.xz" "bison-$BISON_VER.tar.xz" "bison-$BISON_VER"

cd "$DEP_DIR/bison-$BISON_VER"
if [ -f "Makefile" ]; then
    make distclean >/dev/null 2>&1 || true
fi
rm -f config.cache config.status
./configure --prefix=/usr --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
