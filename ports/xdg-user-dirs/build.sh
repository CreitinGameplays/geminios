#!/bin/bash
set -e

XDG_USER_DIRS_VER="0.18"
download_and_extract \
    "https://user-dirs.freedesktop.org/releases/xdg-user-dirs-$XDG_USER_DIRS_VER.tar.gz" \
    "xdg-user-dirs-$XDG_USER_DIRS_VER.tar.gz" \
    "xdg-user-dirs-$XDG_USER_DIRS_VER"

cd "$DEP_DIR/xdg-user-dirs-$XDG_USER_DIRS_VER"
./configure --prefix=/usr --sysconfdir=/etc --disable-static --disable-documentation --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
