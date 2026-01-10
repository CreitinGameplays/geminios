#!/bin/bash
set -e
XKEYBOARD_CONFIG_VER="2.34"
download_and_extract "https://www.x.org/archive/individual/data/xkeyboard-config/xkeyboard-config-$XKEYBOARD_CONFIG_VER.tar.gz" "xkeyboard-config-$XKEYBOARD_CONFIG_VER.tar.gz" "xkeyboard-config-$XKEYBOARD_CONFIG_VER"
cd "$DEP_DIR/xkeyboard-config-$XKEYBOARD_CONFIG_VER"
./configure --prefix=/usr --with-xkb-base=/usr/share/X11/xkb --disable-runtime-deps --host=x86_64-linux-gnu
make install DESTDIR="$ROOTFS"
