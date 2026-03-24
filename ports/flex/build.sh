#!/bin/bash
set -e

FLEX_VER="2.6.4"
download_and_extract "https://github.com/westes/flex/releases/download/v$FLEX_VER/flex-$FLEX_VER.tar.gz" "flex-$FLEX_VER.tar.gz" "flex-$FLEX_VER"

cd "$DEP_DIR/flex-$FLEX_VER"
if [ -f "Makefile" ]; then
    make distclean >/dev/null 2>&1 || true
fi
rm -f config.cache config.status
./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
ln -sf flex "$ROOTFS/usr/bin/lex" || true
