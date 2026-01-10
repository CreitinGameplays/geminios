#!/bin/bash
set -e
PCIUTILS_VER="3.14.0"
download_and_extract "https://mj.ucw.cz/download/linux/pci/pciutils-$PCIUTILS_VER.tar.gz" "pciutils-$PCIUTILS_VER.tar.gz" "pciutils-$PCIUTILS_VER"
cd "$DEP_DIR/pciutils-$PCIUTILS_VER"

# pciutils uses a Makefile instead of configure
# We disable shared libraries for simplicity in this static-heavy environment
make -j$JOBS PREFIX=/usr SHARED=no ZLIB=no HWDB=no
make install DESTDIR="$ROOTFS" PREFIX=/usr SHARED=no
