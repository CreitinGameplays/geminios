#!/bin/bash
set -e

CURL_VER="8.7.1"
download_and_extract "https://curl.se/download/curl-$CURL_VER.tar.xz" "curl-$CURL_VER.tar.xz" "curl-$CURL_VER"

cd "$DEP_DIR/curl-$CURL_VER"

export CC="gcc"
export LDFLAGS="--sysroot=$ROOTFS"
export PKG_CONFIG="/bin/false"

./configure --prefix=/usr \
            --libdir=/usr/lib/x86_64-linux-gnu \
            --with-openssl \
            --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
            --with-ca-path=/etc/ssl/certs \
            --disable-static \
            --disable-ldap \
            --disable-ldaps \
            --without-libpsl \
            --without-brotli \
            --without-nghttp2 \
            --without-zstd \
            --disable-docs \
            --disable-manual

make -j$JOBS
make install DESTDIR="$ROOTFS"
