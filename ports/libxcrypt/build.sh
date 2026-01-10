#!/bin/bash
set -e

LIBXCRYPT_VER="4.4.36"
download_and_extract "https://github.com/besser82/libxcrypt/releases/download/v$LIBXCRYPT_VER/libxcrypt-$LIBXCRYPT_VER.tar.xz" "libxcrypt-$LIBXCRYPT_VER.tar.xz" "libxcrypt-$LIBXCRYPT_VER"

cd "$DEP_DIR/libxcrypt-$LIBXCRYPT_VER"

# Configure if not already configured
if [ ! -f "Makefile" ]; then
    PERL=/usr/bin/perl ./configure --prefix=/usr \
                --enable-static \
                --enable-hashes=all \
                --enable-obsolete-api=glibc \
                --disable-werror
fi

make -j$JOBS
make install DESTDIR="$ROOTFS"

# Ensure libcrypt.so.1 is in lib64 if it ended up in lib
if [ -f "$ROOTFS/usr/lib/libcrypt.so.1" ] && [ ! -f "$ROOTFS/lib64/libcrypt.so.1" ]; then
    cp -d "$ROOTFS/usr/lib/libcrypt.so.1"* "$ROOTFS/lib64/"
fi
