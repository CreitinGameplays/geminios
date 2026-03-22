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

if [ -f "$ROOT_DIR/rootfs/usr/lib64/libudev.la" ]; then
    sed -i "s|^dependency_libs=.*$|dependency_libs=''|" "$ROOT_DIR/rootfs/usr/lib64/libudev.la"
fi

XORG_SERVER_VER="1.20.14"
download_and_extract "https://www.x.org/archive/individual/xserver/xorg-server-$XORG_SERVER_VER.tar.gz" "xorg-server-$XORG_SERVER_VER.tar.gz" "xorg-server-$XORG_SERVER_VER"
cd "$DEP_DIR/xorg-server-$XORG_SERVER_VER"

# Apply patch if not already applied
if ! grep -q "#undef bool" glx/glxdri2.c; then
    patch -p1 < "$ROOT_DIR/patches/xorg-server-1.20.14-glxdri2.patch"
fi

# Build with the host toolchain, but resolve GeminiOS dependencies from the
# staged rootfs. Some pkg-config files inject -I$ROOTFS/usr/include, which
# pulls in the kernel's stddef.h and breaks glibc headers during compile.
export CC="${CC:-cc}"
export CXX="${CXX:-c++}"
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib64/pkgconfig:$ROOTFS/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"
export CFLAGS="-O2 -fPIC -Wno-error -Wno-redundant-decls -Dbool=xorg_bool"
export CXXFLAGS="-O2 -fPIC -Wno-error -Wno-redundant-decls -Dbool=xorg_bool"
export CPPFLAGS="-Dbool=xorg_bool"
export LDFLAGS=""

PKG_CONFIG_REAL="${PKG_CONFIG:-pkg-config}"
PKG_CONFIG_FILTER="$PWD/pkg-config-xorg-server-filter.sh"
cat > "$PKG_CONFIG_FILTER" <<EOF
#!/bin/sh
set -e
out="\$($PKG_CONFIG_REAL "\$@")"
filtered=""
for token in \$out; do
    if [ "\$token" = "-I$ROOTFS/usr/include" ]; then
        filtered="\$filtered -idirafter $ROOTFS/usr/include"
        continue
    fi
    filtered="\$filtered \$token"
done
printf '%s\n' "\${filtered# }"
EOF
chmod 755 "$PKG_CONFIG_FILTER"
export PKG_CONFIG="$PKG_CONFIG_FILTER"

sanitize_generated_la() {
    find . -name '*.la' -type f -exec sed -i "s| -L$ROOTFS/lib64||g" {} +
}

./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc --localstatedir=/var \
    --disable-static --enable-xorg --enable-xwayland --disable-xephyr --disable-xvfb \
    --disable-xnest --enable-config-udev --disable-config-udev-kms --disable-config-hal \
    --disable-systemd-logind --enable-glx --enable-dri --enable-dri2 --enable-dri3 \
    --enable-fbdev --enable-libdrm --disable-unit-tests --enable-glamor --disable-selective-werror \
    --with-xkb-bin-directory=/usr/bin --with-xkb-path=/usr/share/X11/xkb --with-xkb-output=/var/lib/xkb \
    --host=x86_64-linux-gnu
if ! make -j$JOBS; then
    sanitize_generated_la
    make -j$JOBS
fi
make install DESTDIR="$ROOTFS"
rm -f "$PKG_CONFIG_FILTER"
ln -sf Xorg "$ROOTFS/usr/bin/X"
