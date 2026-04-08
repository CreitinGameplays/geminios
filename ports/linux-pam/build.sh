#!/bin/bash
set -e

PAM_VER="1.7.1"
download_and_extract \
    "https://github.com/linux-pam/linux-pam/releases/download/v$PAM_VER/Linux-PAM-$PAM_VER.tar.xz" \
    "Linux-PAM-$PAM_VER.tar.xz" \
    "Linux-PAM-$PAM_VER"

cd "$DEP_DIR/Linux-PAM-$PAM_VER"
rm -rf build

export CC="${CC:-cc}"
export CXX="${CXX:-c++}"
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig:$ROOTFS/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"
export CFLAGS="-O2 -fPIC -Wno-error"
export CXXFLAGS="-O2 -fPIC -Wno-error"
export LDFLAGS=""

PKG_CONFIG_REAL="${PKG_CONFIG:-pkg-config}"
PKG_CONFIG_FILTER="$PWD/pkg-config-linux-pam-filter.sh"
cat > "$PKG_CONFIG_FILTER" <<EOF
#!/bin/sh
set -e
out="\$($PKG_CONFIG_REAL "\$@")"
filtered=""
for token in \$out; do
    if [ "\$token" = "-I$ROOTFS/usr/include" ]; then
        continue
    fi
    filtered="\$filtered \$token"
done
printf '%s\n' "\${filtered# }"
EOF
chmod 755 "$PKG_CONFIG_FILTER"
export PKG_CONFIG="$PKG_CONFIG_FILTER"

meson setup build \
    --prefix=/usr \
    --libdir=lib/x86_64-linux-gnu \
    --sbindir=sbin \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --buildtype=release \
    -Ddocs=disabled \
    -Dlogind=disabled \
    -Delogind=disabled \
    -Daudit=disabled \
    -Dselinux=enabled \
    -Dnis=disabled \
    -Deconf=disabled

ninja -C build
DESTDIR="$ROOTFS" ninja -C build install

rm -f "$PKG_CONFIG_FILTER"
rm -rf "$ROOTFS/usr/lib/systemd"
if [ -f "$ROOTFS/usr/sbin/unix_chkpwd" ]; then
    chmod 4755 "$ROOTFS/usr/sbin/unix_chkpwd"
fi
