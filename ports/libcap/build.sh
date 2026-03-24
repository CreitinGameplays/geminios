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

# Build the runtime library against the staged target sysroot, but keep the
# small code-generation helper on the host toolchain so it can execute during
# the build.
make -j"$JOBS" \
    prefix=/usr \
    lib=lib/x86_64-linux-gnu \
    RAISE_SETFCAP=no \
    PAM_CAP=no \
    BUILD_CC=/usr/bin/gcc \
    BUILD_CFLAGS="-O2"
make \
    prefix=/usr \
    lib=lib/x86_64-linux-gnu \
    RAISE_SETFCAP=no \
    PAM_CAP=no \
    BUILD_CC=/usr/bin/gcc \
    BUILD_CFLAGS="-O2" \
    DESTDIR="$ROOTFS" \
    install
