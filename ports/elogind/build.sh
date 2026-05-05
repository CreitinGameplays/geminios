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
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig:$ROOTFS/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"
export CFLAGS="${CFLAGS:+$CFLAGS }-Wno-error"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-Wno-error"
export LDFLAGS="${LDFLAGS:+$LDFLAGS }-Wl,-rpath-link,$ROOTFS/usr/lib/x86_64-linux-gnu -Wl,-rpath-link,$ROOTFS/lib/x86_64-linux-gnu"
PYTHON_SITE_PACKAGES=(
    "$ROOTFS/usr/lib/x86_64-linux-gnu/python3.11/site-packages"
    "$ROOTFS/usr/lib/python3.11/site-packages"
)
PYTHONPATH_PREFIX=""
for candidate in "${PYTHON_SITE_PACKAGES[@]}"; do
    if [ -d "$candidate" ]; then
        if [ -n "$PYTHONPATH_PREFIX" ]; then
            PYTHONPATH_PREFIX="$PYTHONPATH_PREFIX:$candidate"
        else
            PYTHONPATH_PREFIX="$candidate"
        fi
    fi
done
export PYTHONPATH="$PYTHONPATH_PREFIX${PYTHONPATH:+:$PYTHONPATH}"

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
        filtered="\$filtered -idirafter $ROOTFS/usr/include"
        continue
    fi
    filtered="\$filtered \$token"
done
printf '%s\n' "\${filtered# }"
EOF
chmod 755 "$PKG_CONFIG_FILTER"
export PKG_CONFIG="$PKG_CONFIG_FILTER"

audit_feature="auto"
if [ ! -f "$ROOTFS/usr/include/libaudit.h" ] || \
   { [ ! -e "$ROOTFS/usr/lib/x86_64-linux-gnu/libaudit.so" ] && [ ! -e "$ROOTFS/usr/lib/x86_64-linux-gnu/libaudit.a" ]; }; then
    echo "Disabling audit support for elogind; staged libaudit development files are incomplete."
    audit_feature="disabled"
fi

meson setup build \
    --prefix=/usr \
    --libdir=lib/x86_64-linux-gnu \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --buildtype=release \
    -Dman=false \
    -Dhtml=false \
    -Dcgroup-controller=elogind \
    -Ddev-kvm-mode=0660 \
    -Ddbuspolicydir=/etc/dbus-1/system.d \
    -Ddefault-kill-user-processes=false \
    "-Daudit=$audit_feature"

ninja -C build
DESTDIR="$ROOTFS" ninja -C build install

mkdir -p "$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig" "$ROOTFS/usr/include"
mkdir -p "$ROOTFS/usr/include/systemd" "$ROOTFS/usr/include/elogind/systemd"

for header_path in "$DEP_DIR/elogind-$ELOGIND_VER"/src/systemd/*.h; do
    [ -f "$header_path" ] || continue
    header_name="$(basename "$header_path")"
    install -m 0644 "$header_path" "$ROOTFS/usr/include/elogind/systemd/$header_name"
    ln -sfn "../elogind/systemd/$header_name" "$ROOTFS/usr/include/systemd/$header_name"
done

if [ -f "$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig/libelogind.pc" ]; then
    sed \
        -e 's|^includedir=.*|includedir=/usr/include|' \
        -e 's|^Name: .*|Name: systemd|' \
        -e 's|^Description: .*|Description: systemd compatibility library provided by elogind|' \
        "$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig/libelogind.pc" \
        > "$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig/libsystemd.pc"
fi

if [ -e "$ROOTFS/usr/lib/x86_64-linux-gnu/libelogind.so" ]; then
    ln -sf libelogind.so "$ROOTFS/usr/lib/x86_64-linux-gnu/libsystemd.so"
fi
if [ -e "$ROOTFS/usr/lib/x86_64-linux-gnu/libelogind.so.0" ]; then
    ln -sf libelogind.so.0 "$ROOTFS/usr/lib/x86_64-linux-gnu/libsystemd.so.0"
fi
