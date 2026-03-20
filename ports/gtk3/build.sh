#!/bin/bash
set -e
GTK3_VER="3.24.41"
download_and_extract "https://download.gnome.org/sources/gtk+/3.24/gtk+-$GTK3_VER.tar.xz" "gtk+-$GTK3_VER.tar.xz" "gtk+-$GTK3_VER"    
cd "$DEP_DIR/gtk+-$GTK3_VER"
rm -rf build

# GTK3 is a native Meson build here. Point dependency discovery at the
# GeminiOS rootfs, but do not use the in-progress sysroot as the C runtime
# for Meson's compiler sanity checks.
export CC="${CC:-cc}"
export CXX="${CXX:-c++}"
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib64/pkgconfig:$ROOTFS/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"
export CFLAGS="-O2 -fPIC -Wno-error"
export CXXFLAGS="-O2 -fPIC -Wno-error"
export LDFLAGS=""

PKG_CONFIG_REAL="${PKG_CONFIG:-pkg-config}"
PKG_CONFIG_FILTER="$PWD/pkg-config-gtk3-filter.sh"
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

required_modules=(
    wayland-client
    wayland-cursor
    wayland-egl
    xkbcommon
    epoxy
    atk
    atk-bridge-2.0
    pango
    pangocairo
    cairo
    cairo-xlib
    gdk-pixbuf-2.0
)
for module in "${required_modules[@]}"; do
    if ! pkg-config --exists "$module"; then
        echo "ERROR: Missing required GTK3 dependency: $module"
        exit 1
    fi
done

meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dintrospection=false -Ddemos=false -Dexamples=false -Dtests=false -Dwayland_backend=true -Dx11_backend=true -Dwerror=false
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install

rm -f "$PKG_CONFIG_FILTER"

for pc in gdk-wayland-3.0.pc gtk+-wayland-3.0.pc; do
    if [ ! -f "$ROOTFS/usr/lib64/pkgconfig/$pc" ]; then
        echo "ERROR: GTK3 build is missing $pc; Wayland backend was not enabled correctly."
        exit 1
    fi
done

if ! nm -D "$ROOTFS/usr/lib64/libgdk-3.so" | grep -q ' gdk_wayland_seat_get_wl_seat$'; then
    echo "ERROR: GTK3 build is missing GDK Wayland symbols."
    exit 1
fi
