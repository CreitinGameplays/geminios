#!/bin/bash
set -e

OPENSSL_VER="3.3.0"
download_and_extract "https://www.openssl.org/source/openssl-$OPENSSL_VER.tar.gz" "openssl-$OPENSSL_VER.tar.gz" "openssl-$OPENSSL_VER"

cd "$DEP_DIR/openssl-$OPENSSL_VER"
./config --prefix=/usr --libdir=lib/x86_64-linux-gnu --openssldir=/etc/ssl shared zlib-dynamic no-tests no-docs
make -j$JOBS
make install DESTDIR="$ROOTFS"

# Normalize OpenSSL's Debian-style sysroot layout. The staged compiler searches
# usr/include/x86_64-linux-gnu before usr/include, so keep the multiarch
# compatibility header tree pointing at the freshly installed OpenSSL headers
# instead of the stale bootstrap copy.
OPENSSL_MULTIARCH_INCLUDE_DIR="$ROOTFS/usr/include/x86_64-linux-gnu/openssl"
rm -rf "$OPENSSL_MULTIARCH_INCLUDE_DIR"
mkdir -p "$(dirname "$OPENSSL_MULTIARCH_INCLUDE_DIR")"
ln -s ../../openssl "$OPENSSL_MULTIARCH_INCLUDE_DIR"

# OpenSSL's generated pkg-config files still advertise /usr/lib64. Rewrite
# them to the canonical Debian multiarch directory so consumers such as curl
# stay inside the staged sysroot.
for pc in \
    "$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig/libcrypto.pc" \
    "$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig/libssl.pc" \
    "$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig/openssl.pc"
do
    [ -f "$pc" ] || continue
    sed -i 's|^libdir=/usr/lib64$|libdir=/usr/lib/x86_64-linux-gnu|' "$pc"
done
