#!/bin/bash
set -e
PKG_VER="9.4"
PKG_NAME="coreutils"
SRC_URL="https://ftp.gnu.org/gnu/coreutils/coreutils-$PKG_VER.tar.xz"
ARCHIVE="coreutils-$PKG_VER.tar.xz"
DIR="coreutils-$PKG_VER"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"

# Force regeneration of configure to avoid issues with old timestamps
# autoreconf -fiv

./configure --prefix=/usr \
            --libexecdir=/usr/lib \
            --enable-no-install-program=kill,uptime

make -j$JOBS
make install DESTDIR="$ROOTFS"

# Move essential binaries to /bin
mkdir -p "$ROOTFS/bin"
ESSENTIALS="cat chgrp chmod chown cp date dd df echo false ln ls mkdir mknod mv pwd rm rmdir sleep stty sync touch true uname"
for prog in $ESSENTIALS; do
    mv -v "$ROOTFS/usr/bin/$prog" "$ROOTFS/bin/$prog"
done
