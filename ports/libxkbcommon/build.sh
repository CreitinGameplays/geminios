#!/bin/bash
set -e
LIBXKBCOMMON_VER="1.6.0"
download_and_extract "https://xkbcommon.org/download/libxkbcommon-$LIBXKBCOMMON_VER.tar.xz" "libxkbcommon-$LIBXKBCOMMON_VER.tar.xz" "libxkbcommon-$LIBXKBCOMMON_VER"
cd "$DEP_DIR/libxkbcommon-$LIBXKBCOMMON_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Denable-x11=true -Denable-wayland=true -Denable-docs=false -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install

for pc in xkbcommon.pc xkbcommon-x11.pc; do
    if [ ! -f "$ROOTFS/usr/lib64/pkgconfig/$pc" ]; then
        echo "ERROR: libxkbcommon build is missing $pc."
        exit 1
    fi
done
