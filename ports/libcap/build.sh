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

# Build libcap with the host compiler. Its makefiles generate helper binaries
# during the build, and linking those against the in-progress sysroot libc
# breaks in the same way Meson sanity checks do.
unset CC CXX CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
make -j"$JOBS" \
    prefix=/usr \
    lib=lib64 \
    RAISE_SETFCAP=no \
    PAM_CAP=no
make \
    prefix=/usr \
    lib=lib64 \
    RAISE_SETFCAP=no \
    PAM_CAP=no \
    DESTDIR="$ROOTFS" \
    install
