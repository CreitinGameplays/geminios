#!/bin/bash
set -e
GAWK_VER="5.3.0"
download_and_extract "https://ftp.gnu.org/gnu/gawk/gawk-$GAWK_VER.tar.xz" "gawk-$GAWK_VER.tar.xz" "gawk-$GAWK_VER"
cd "$DEP_DIR/gawk-$GAWK_VER"
./configure --prefix=/usr --disable-nls --enable-static --disable-extensions --disable-lint LDFLAGS="-static" --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
ln -sf gawk "$ROOTFS/usr/bin/awk"
