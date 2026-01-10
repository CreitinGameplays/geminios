#!/bin/bash
set -e

LIBXDMCP_VER="1.1.5"
download_and_extract "https://www.x.org/archive/individual/lib/libXdmcp-$LIBXDMCP_VER.tar.gz" "libXdmcp-$LIBXDMCP_VER.tar.gz" "libXdmcp-$LIBXDMCP_VER"

cd "$DEP_DIR/libXdmcp-$LIBXDMCP_VER"
./configure --prefix=/usr --sysconfdir=/etc --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
