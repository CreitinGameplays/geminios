#!/bin/bash
set -e
HARFBUZZ_VER="8.3.0"
download_and_extract "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VER/harfbuzz-$HARFBUZZ_VER.tar.xz" "harfbuzz-$HARFBUZZ_VER.tar.xz" "harfbuzz-$HARFBUZZ_VER"
cd "$DEP_DIR/harfbuzz-$HARFBUZZ_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dglib=enabled -Dfreetype=enabled -Dgobject=enabled -Dintrospection=disabled -Dcairo=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
