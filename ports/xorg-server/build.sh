#!/bin/bash
set -e

# Auto-detect project root directory
if [ -z "$ROOT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
    export ROOT_DIR
fi

# Fix broken libXfont2.la path if it exists
if [ -f "$ROOT_DIR/rootfs/usr/lib64/libXfont2.la" ]; then
    sed -i "s|/usr/lib/libfontenc.la|$ROOT_DIR/rootfs/usr/lib64/libfontenc.la|g" "$ROOT_DIR/rootfs/usr/lib64/libXfont2.la"
fi

# Fix missing libudev.la
if [ ! -f "$ROOT_DIR/rootfs/usr/lib64/libudev.la" ]; then
    echo "libudev.la not found in rootfs. Attempting to recover..."
    # Try to find it in external_dependencies
    FOUND_LA=$(find "$DEP_DIR" -name "libudev.la" 2>/dev/null | grep "src/libudev/libudev.la" | head -n 1)
    if [ -n "$FOUND_LA" ]; then
        echo "Found libudev.la at $FOUND_LA. Installing to rootfs..."
        cp "$FOUND_LA" "$ROOT_DIR/rootfs/usr/lib64/libudev.la"
        sed -i "s/installed=no/installed=yes/g" "$ROOT_DIR/rootfs/usr/lib64/libudev.la"
    else
        echo "Warning: libudev.la not found in dependencies. Build might fail."
    fi
fi

XORG_SERVER_VER="1.20.14"
download_and_extract "https://www.x.org/archive/individual/xserver/xorg-server-$XORG_SERVER_VER.tar.gz" "xorg-server-$XORG_SERVER_VER.tar.gz" "xorg-server-$XORG_SERVER_VER"
cd "$DEP_DIR/xorg-server-$XORG_SERVER_VER"

# Apply patch if not already applied
if ! grep -q "#undef bool" glx/glxdri2.c; then
    patch -p1 < "$ROOT_DIR/patches/xorg-server-1.20.14-glxdri2.patch"
fi

./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc --localstatedir=/var \
    --disable-static --enable-xorg --disable-xwayland --disable-xephyr --disable-xvfb \
    --disable-xnest --enable-config-udev --disable-config-udev-kms --disable-config-hal \
    --disable-systemd-logind --enable-glx --enable-dri --enable-dri2 --enable-dri3 \
    --enable-fbdev --enable-libdrm --disable-unit-tests --enable-glamor --disable-selective-werror \
    --with-xkb-bin-directory=/usr/bin --with-xkb-path=/usr/share/X11/xkb --with-xkb-output=/var/lib/xkb \
    CFLAGS="-O2 -Wno-error -Wno-redundant-decls -Dbool=xorg_bool" CPPFLAGS="-Dbool=xorg_bool" --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
ln -sf Xorg "$ROOTFS/usr/bin/X"
