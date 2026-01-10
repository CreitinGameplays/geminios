#!/bin/bash
set -e
GDK_PIXBUF_VER="2.42.10"
download_and_extract "https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-$GDK_PIXBUF_VER.tar.xz" "gdk-pixbuf-$GDK_PIXBUF_VER.tar.xz" "gdk-pixbuf-$GDK_PIXBUF_VER"
cd "$DEP_DIR/gdk-pixbuf-$GDK_PIXBUF_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dintrospection=disabled -Dman=false -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
