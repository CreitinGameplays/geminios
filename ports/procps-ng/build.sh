#!/bin/bash
set -e
PKG_VER="4.0.4"
PKG_NAME="procps-ng"
SRC_URL="https://sourceforge.net/projects/procps-ng/files/Production/procps-ng-$PKG_VER.tar.xz"
ARCHIVE="procps-ng-$PKG_VER.tar.xz"
DIR="procps-ng-$PKG_VER"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"

./configure --prefix=/usr \
            --exec-prefix= \
            --libdir=/usr/lib64 \
            --docdir=/usr/share/doc/procps-ng-$PKG_VER \
            --disable-static \
            --disable-kill \
            --without-systemd \
            LIBS="-ltinfow"

# We disable kill because util-linux provides it (or we enabled it there). 
# Actually, procps-ng kill is usually preferred over util-linux kill? 
# util-linux has --enable-kill. procps-ng has pkill.
# Let's keep procps-ng kill disabled to avoid conflict if util-linux installs it.
# util-linux build.sh currently has --enable-kill.

make -j$JOBS
make install DESTDIR="$ROOTFS"

# Move essential libraries to /lib64 if they ended up in /usr/lib64 and are needed for boot (not strictly necessary with merged usr, but safe)
# procps 4.x puts libs in /usr/lib64 usually.
