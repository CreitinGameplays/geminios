#!/bin/bash
set -e

OPENSSL_VER="3.3.0"
download_and_extract "https://www.openssl.org/source/openssl-$OPENSSL_VER.tar.gz" "openssl-$OPENSSL_VER.tar.gz" "openssl-$OPENSSL_VER"

cd "$DEP_DIR/openssl-$OPENSSL_VER"
./config --prefix=/usr --libdir=lib64 --openssldir=/etc/ssl shared zlib-dynamic
make -j$JOBS
make install DESTDIR="$ROOTFS"
