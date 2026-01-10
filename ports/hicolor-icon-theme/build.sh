#!/bin/bash
set -e
HICOLOR_ICON_THEME_VER="0.17"
download_and_extract "https://icon-theme.freedesktop.org/releases/hicolor-icon-theme-$HICOLOR_ICON_THEME_VER.tar.xz" "hicolor-icon-theme-$HICOLOR_ICON_THEME_VER.tar.xz" "hicolor-icon-theme-$HICOLOR_ICON_THEME_VER"
cd "$DEP_DIR/hicolor-icon-theme-$HICOLOR_ICON_THEME_VER"
./configure --prefix=/usr --host=x86_64-linux-gnu
make install DESTDIR="$ROOTFS"
