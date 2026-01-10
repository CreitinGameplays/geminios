#!/bin/bash
set -e

LIBFFI_VER="3.4.4"
download_and_extract "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VER/libffi-$LIBFFI_VER.tar.gz" "libffi-$LIBFFI_VER.tar.gz" "libffi-$LIBFFI_VER"

cd "$DEP_DIR/libffi-$LIBFFI_VER"

# Apply patch if not already applied
if ! grep -q "open_temp_exec_file" src/tramp.c; then
    patch -p1 < "$ROOT_DIR/patches/libffi-3.4.4.patch"
fi

./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
