#!/bin/bash
set -e
ADWAITA_ICON_THEME_VER="42.0"
download_and_extract "https://download.gnome.org/sources/adwaita-icon-theme/42/adwaita-icon-theme-$ADWAITA_ICON_THEME_VER.tar.xz" "adwaita-icon-theme-$ADWAITA_ICON_THEME_VER.tar.xz" "adwaita-icon-theme-$ADWAITA_ICON_THEME_VER"
cd "$DEP_DIR/adwaita-icon-theme-$ADWAITA_ICON_THEME_VER"
# The host may provide gtk-encode-symbolic-svg, but this build environment
# does not stage the SVG pixbuf loader that tool depends on. Disable the
# optional symbolic PNG conversion path and install the scalable icons only.
ac_cv_path_GTK_ENCODE_SYMBOLIC_SVG=false ./configure --prefix=/usr --host=x86_64-linux-gnu
make install DESTDIR="$ROOTFS"
