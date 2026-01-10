#!/bin/bash
set -e
LIBWNCK_VER="3.36.0"
download_and_extract "https://download.gnome.org/sources/libwnck/3.36/libwnck-$LIBWNCK_VER.tar.xz" "libwnck-$LIBWNCK_VER.tar.xz" "libwnck-$LIBWNCK_VER"
cd "$DEP_DIR/libwnck-$LIBWNCK_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dintrospection=disabled -Dstartup_notification=enabled
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
