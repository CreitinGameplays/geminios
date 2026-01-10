#!/bin/bash
set -e

GPERF_VER="3.1"
download_and_extract "https://ftp.gnu.org/pub/gnu/gperf/gperf-$GPERF_VER.tar.gz" "gperf-$GPERF_VER.tar.gz" "gperf-$GPERF_VER"

cd "$DEP_DIR/gperf-$GPERF_VER"
if [ ! -f "Makefile" ]; then
    ./configure --prefix=/usr --docdir=/usr/share/doc/gperf-$GPERF_VER --host=x86_64-linux-gnu
fi
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
