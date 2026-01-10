#!/bin/bash
set -e
ADWAITA_ICON_THEME_VER="42.0"
download_and_extract "https://download.gnome.org/sources/adwaita-icon-theme/42/adwaita-icon-theme-$ADWAITA_ICON_THEME_VER.tar.xz" "adwaita-icon-theme-$ADWAITA_ICON_THEME_VER.tar.xz" "adwaita-icon-theme-$ADWAITA_ICON_THEME_VER"
cd "$DEP_DIR/adwaita-icon-theme-$ADWAITA_ICON_THEME_VER"
./configure --prefix=/usr --host=x86_64-linux-gnu
make install DESTDIR="$ROOTFS"
