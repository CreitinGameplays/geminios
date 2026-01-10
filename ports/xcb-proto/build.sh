#!/bin/bash
set -e

XCB_PROTO_VER="1.16.0"
download_and_extract "https://www.x.org/archive/individual/proto/xcb-proto-$XCB_PROTO_VER.tar.gz" "xcb-proto-$XCB_PROTO_VER.tar.gz" "xcb-proto-$XCB_PROTO_VER"

cd "$DEP_DIR/xcb-proto-$XCB_PROTO_VER"
./configure --prefix=/usr --host=x86_64-linux-gnu
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
