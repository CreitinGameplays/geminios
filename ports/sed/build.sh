#!/bin/bash
set -e
SED_VER="4.9"
download_and_extract "https://ftp.gnu.org/gnu/sed/sed-$SED_VER.tar.xz" "sed-$SED_VER.tar.xz" "sed-$SED_VER"
cd "$DEP_DIR/sed-$SED_VER"
./configure --prefix=/usr --disable-nls --enable-static LDFLAGS="-static" --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
