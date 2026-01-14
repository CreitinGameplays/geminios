#!/bin/bash
set -e
BASH_VER="5.2.21"
download_and_extract "https://ftp.gnu.org/gnu/bash/bash-$BASH_VER.tar.gz" "bash-$BASH_VER.tar.gz" "bash-$BASH_VER"
cd "$DEP_DIR/bash-$BASH_VER"
./configure --prefix=/usr --enable-static-link --without-bash-malloc --disable-nls \
    --disable-shared --disable-curses LDFLAGS="-static" --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
mkdir -p "$ROOTFS/bin"
ln -sf ../usr/bin/bash "$ROOTFS/bin/bash"
ln -sf bash "$ROOTFS/bin/sh"
