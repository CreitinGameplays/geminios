#!/bin/bash
set -e

ELOGIND_VER="255.22"
download_and_extract \
    "https://github.com/elogind/elogind/archive/v$ELOGIND_VER/elogind-$ELOGIND_VER.tar.gz" \
    "elogind-$ELOGIND_VER.tar.gz" \
    "elogind-$ELOGIND_VER"

cd "$DEP_DIR/elogind-$ELOGIND_VER"
rm -rf build

meson setup build \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --buildtype=release \
    -Dman=false \
    -Dhtml=false \
    -Dcgroup-controller=elogind \
    -Ddev-kvm-mode=0660 \
    -Ddbuspolicydir=/etc/dbus-1/system.d \
    -Ddefault-kill-user-processes=false

ninja -C build
DESTDIR="$ROOTFS" ninja -C build install

mkdir -p "$ROOTFS/usr/lib64/pkgconfig" "$ROOTFS/usr/include"
ln -sf libelogind.pc "$ROOTFS/usr/lib64/pkgconfig/libsystemd.pc"
ln -sf elogind "$ROOTFS/usr/include/systemd"

if [ -e "$ROOTFS/usr/lib64/libelogind.so" ]; then
    ln -sf libelogind.so "$ROOTFS/usr/lib64/libsystemd.so"
fi
if [ -e "$ROOTFS/usr/lib64/libelogind.so.0" ]; then
    ln -sf libelogind.so.0 "$ROOTFS/usr/lib64/libsystemd.so.0"
fi
