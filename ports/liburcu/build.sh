#!/bin/bash
set -euo pipefail

LIBURCU_VER="0.14.0"
LIBURCU_TAG="v$LIBURCU_VER"
LIBURCU_ARCHIVE="userspace-rcu-$LIBURCU_TAG.tar.gz"
LIBURCU_URL="https://github.com/urcu/userspace-rcu/archive/refs/tags/$LIBURCU_TAG.tar.gz"
LIBURCU_DIR="userspace-rcu-$LIBURCU_VER"

mkdir -p "$DEP_DIR"
if [ ! -d "$DEP_DIR/$LIBURCU_DIR" ]; then
    rm -f "$DEP_DIR/$LIBURCU_ARCHIVE"
    wget -q -O "$DEP_DIR/$LIBURCU_ARCHIVE" "$LIBURCU_URL"
    EXTRACTED_DIR="$(tar -tf "$DEP_DIR/$LIBURCU_ARCHIVE" | head -1 | cut -d/ -f1)"
    tar -xf "$DEP_DIR/$LIBURCU_ARCHIVE" -C "$DEP_DIR"
    rm -rf "$DEP_DIR/$LIBURCU_DIR"
    mv "$DEP_DIR/$EXTRACTED_DIR" "$DEP_DIR/$LIBURCU_DIR"
    rm -f "$DEP_DIR/$LIBURCU_ARCHIVE"
fi

cd "$DEP_DIR/$LIBURCU_DIR"
make distclean || true

if [ ! -x ./configure ]; then
    sh ./bootstrap
fi

./configure \
    --prefix=/usr \
    --bindir=/bin \
    --sbindir=/sbin \
    --libdir=/usr/lib/x86_64-linux-gnu \
    --disable-static \
    --disable-numa \
    --host=x86_64-linux-gnu

make -j"$JOBS"
make install DESTDIR="$ROOTFS"
