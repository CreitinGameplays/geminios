#!/bin/bash
set -e

LIBXCRYPT_VER="4.4.36"
download_and_extract "https://github.com/besser82/libxcrypt/releases/download/v$LIBXCRYPT_VER/libxcrypt-$LIBXCRYPT_VER.tar.xz" "libxcrypt-$LIBXCRYPT_VER.tar.xz" "libxcrypt-$LIBXCRYPT_VER"

cd "$DEP_DIR/libxcrypt-$LIBXCRYPT_VER"

if [ -f "Makefile" ]; then
    make distclean >/dev/null 2>&1 || true
fi
rm -f config.cache config.status
PERL=/usr/bin/perl ./configure --prefix=/usr \
            --enable-static \
            --enable-hashes=all \
            --enable-obsolete-api=glibc \
            --disable-werror

make -j$JOBS
make install DESTDIR="$ROOTFS"

# Ensure libcrypt.so.1 is in the canonical runtime directory if upstream
# leaves it under /usr/lib.
if [ -f "$ROOTFS/usr/lib/libcrypt.so.1" ] && [ ! -f "$ROOTFS/lib/x86_64-linux-gnu/libcrypt.so.1" ]; then
    mkdir -p "$ROOTFS/lib/x86_64-linux-gnu"
    cp -d "$ROOTFS/usr/lib/libcrypt.so.1"* "$ROOTFS/lib/x86_64-linux-gnu/"
fi
