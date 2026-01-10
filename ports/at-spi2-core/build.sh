#!/bin/bash
set -e
AT_SPI2_CORE_VER="2.38.0"
download_and_extract "https://download.gnome.org/sources/at-spi2-core/2.38/at-spi2-core-$AT_SPI2_CORE_VER.tar.xz" "at-spi2-core-$AT_SPI2_CORE_VER.tar.xz" "at-spi2-core-$AT_SPI2_CORE_VER"
cd "$DEP_DIR/at-spi2-core-$AT_SPI2_CORE_VER"
rm -rf build
meson setup build --prefix=/usr --libdir=lib64 -Dintrospection=no -Dx11=yes -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install
