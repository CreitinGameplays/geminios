#!/bin/bash
set -e

PCRE2_VER="10.42"
download_and_extract "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VER/pcre2-$PCRE2_VER.tar.bz2" "pcre2-$PCRE2_VER.tar.bz2" "pcre2-$PCRE2_VER"

cd "$DEP_DIR/pcre2-$PCRE2_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --enable-unicode --enable-jit --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
