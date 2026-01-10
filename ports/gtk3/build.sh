#!/bin/bash
set -e
GTK3_VER="3.24.41"
download_and_extract "https://download.gnome.org/sources/gtk+/3.24/gtk+-$GTK3_VER.tar.xz" "gtk+-$GTK3_VER.tar.xz" "gtk+-$GTK3_VER"    
cd "$DEP_DIR/gtk+-$GTK3_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dintrospection=false -Ddemos=false -Dexamples=false -Dtests=false -Dwayland_backend=false -Dx11_backend=true -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
