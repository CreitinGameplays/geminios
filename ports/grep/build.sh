#!/bin/bash
set -e
GREP_VER="3.11"
download_and_extract "https://ftp.gnu.org/gnu/grep/grep-$GREP_VER.tar.xz" "grep-$GREP_VER.tar.xz" "grep-$GREP_VER"
cd "$DEP_DIR/grep-$GREP_VER"
./configure --prefix=/usr --disable-perl-regexp --disable-nls --enable-static LDFLAGS="-static" --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
