#!/bin/bash
set -e

ELOGIND_VER="255.22"
download_and_extract \
    "https://codeload.github.com/elogind/elogind/tar.gz/refs/tags/V$ELOGIND_VER" \
    "elogind-$ELOGIND_VER.tar.gz" \
    "elogind-$ELOGIND_VER"

cd "$DEP_DIR/elogind-$ELOGIND_VER"
rm -rf build

export CC="${CC:-cc}"
export CXX="${CXX:-c++}"
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib64/pkgconfig:$ROOTFS/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"
export CFLAGS="-O2 -fPIC -Wno-error"
export CXXFLAGS="-O2 -fPIC -Wno-error"
export LDFLAGS=""
export PYTHONPATH="$ROOTFS/usr/lib64/python3.11/site-packages${PYTHONPATH:+:$PYTHONPATH}"

# Meson helper scripts use /usr/bin/env python3. Keep a real host python ahead of
# the shim, because the shim intentionally clears PYTHONPATH.
HOST_PYTHON="$HOME/.pyenv/versions/3.11.9/bin/python3"
if [ ! -x "$HOST_PYTHON" ]; then
    HOST_PYTHON="/usr/bin/python3"
fi
export PATH="$(dirname "$HOST_PYTHON"):$PATH"

PKG_CONFIG_REAL="$(command -v pkg-config)"
if [ -z "$PKG_CONFIG_REAL" ]; then
    echo "pkg-config not found in PATH"
    exit 1
fi

PKG_CONFIG_FILTER="$(mktemp "${TMPDIR:-/tmp}/pkg-config-elogind.XXXXXX")"
trap 'rm -f "$PKG_CONFIG_FILTER"' EXIT
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
    --libdir=lib64 \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --buildtype=release \
    -Dman=false \
    -Dhtml=false \
    -Dcgroup-controller=elogind \
    -Ddev-kvm-mode=0660 \
    -Ddbuspolicydir=/etc/dbus-1/system.d \
    -Ddefault-kill-user-processes=false

ninja -C build
DESTDIR="$ROOTFS" ninja -C build install

mkdir -p "$ROOTFS/usr/lib64/pkgconfig" "$ROOTFS/usr/include"
ln -sf libelogind.pc "$ROOTFS/usr/lib64/pkgconfig/libsystemd.pc"
ln -sf elogind "$ROOTFS/usr/include/systemd"

if [ -e "$ROOTFS/usr/lib64/libelogind.so" ]; then
    ln -sf libelogind.so "$ROOTFS/usr/lib64/libsystemd.so"
fi
if [ -e "$ROOTFS/usr/lib64/libelogind.so.0" ]; then
    ln -sf libelogind.so.0 "$ROOTFS/usr/lib64/libsystemd.so.0"
fi
