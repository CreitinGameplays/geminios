#!/bin/bash
set -euo pipefail

INIH_VER="r58"
INIH_ARCHIVE="inih-$INIH_VER.tar.gz"
INIH_URL="https://github.com/benhoyt/inih/archive/refs/tags/$INIH_VER.tar.gz"
INIH_DIR="inih-$INIH_VER"

mkdir -p "$DEP_DIR"
if [ ! -d "$DEP_DIR/$INIH_DIR" ]; then
    rm -f "$DEP_DIR/$INIH_ARCHIVE"
    wget -q -O "$DEP_DIR/$INIH_ARCHIVE" "$INIH_URL"
    EXTRACTED_DIR="$(tar -tf "$DEP_DIR/$INIH_ARCHIVE" | head -1 | cut -d/ -f1)"
    tar -xf "$DEP_DIR/$INIH_ARCHIVE" -C "$DEP_DIR"
    rm -rf "$DEP_DIR/$INIH_DIR"
    mv "$DEP_DIR/$EXTRACTED_DIR" "$DEP_DIR/$INIH_DIR"
    rm -f "$DEP_DIR/$INIH_ARCHIVE"
fi

cd "$DEP_DIR/$INIH_DIR"

mkdir -p "$ROOTFS/usr/include" "$ROOTFS/usr/lib/x86_64-linux-gnu"
rm -f ini.o libinih.so.0.0.0

"$CC" $CFLAGS -c ini.c -o ini.o
"$CC" $LDFLAGS -shared -Wl,-soname,libinih.so.0 -o libinih.so.0.0.0 ini.o

install -Dm644 ini.h "$ROOTFS/usr/include/ini.h"
install -Dm755 libinih.so.0.0.0 "$ROOTFS/usr/lib/x86_64-linux-gnu/libinih.so.0.0.0"
ln -sfn libinih.so.0.0.0 "$ROOTFS/usr/lib/x86_64-linux-gnu/libinih.so.0"
ln -sfn libinih.so.0 "$ROOTFS/usr/lib/x86_64-linux-gnu/libinih.so"
