#!/bin/bash
set -e

LIBCAP_VER="2.76"
download_and_extract \
    "https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-$LIBCAP_VER.tar.xz" \
    "libcap-$LIBCAP_VER.tar.xz" \
    "libcap-$LIBCAP_VER"

cd "$DEP_DIR/libcap-$LIBCAP_VER"
sed -i '/install -m.*STA/d' libcap/Makefile
make clean || true
make -j"$JOBS" prefix=/usr lib=lib64 RAISE_SETFCAP=no
make prefix=/usr lib=lib64 RAISE_SETFCAP=no DESTDIR="$ROOTFS" install
