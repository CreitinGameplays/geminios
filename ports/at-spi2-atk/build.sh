#!/bin/bash
set -e
AT_SPI2_ATK_VER="2.38.0"
download_and_extract "https://download.gnome.org/sources/at-spi2-atk/2.38/at-spi2-atk-$AT_SPI2_ATK_VER.tar.xz" "at-spi2-atk-$AT_SPI2_ATK_VER.tar.xz" "at-spi2-atk-$AT_SPI2_ATK_VER"
cd "$DEP_DIR/at-spi2-atk-$AT_SPI2_ATK_VER"

rm -rf build

# Ensure g-ir-scanner can find the giscanner python module in rootfs
export PYTHONPATH="$ROOTFS/usr/lib64/gobject-introspection:$PYTHONPATH"

meson setup build --prefix=/usr --libdir=lib64 -Dtests=false -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install