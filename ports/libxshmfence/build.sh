#!/bin/bash
set -e
LIBXSHMFENCE_VER="1.3.2"
download_and_extract "https://www.x.org/archive/individual/lib/libxshmfence-$LIBXSHMFENCE_VER.tar.gz" "libxshmfence-$LIBXSHMFENCE_VER.tar.gz" "libxshmfence-$LIBXSHMFENCE_VER"
cd "$DEP_DIR/libxshmfence-$LIBXSHMFENCE_VER"
./configure --prefix=/usr --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
