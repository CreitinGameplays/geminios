#!/bin/bash
set -e
MESA_VER="24.0.0"
download_and_extract "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz" "mesa-$MESA_VER.tar.xz" "mesa-$MESA_VER"
cd "$DEP_DIR/mesa-$MESA_VER"

# Create a shim for python3 to ensure meson uses the wrapper
mkdir -p "$DEP_DIR/bin_shim"
ln -sf "$TARGET_PYTHON" "$DEP_DIR/bin_shim/python3"
export PATH="$DEP_DIR/bin_shim:$PATH"

# Mesa is a native Meson build here. Discover GeminiOS dependencies from the
# rootfs, but keep Meson's compiler sanity checks on the host runtime instead
# of the in-progress target libc.
export CC="${CC:-cc}"
export CXX="${CXX:-c++}"
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib64/pkgconfig:$ROOTFS/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"
export CFLAGS="-O2 -fPIC -Wno-error -idirafter $ROOTFS/usr/include"
export CXXFLAGS="-O2 -fPIC -Wno-error -idirafter $ROOTFS/usr/include"
export LDFLAGS=""

PKG_CONFIG_REAL="${PKG_CONFIG:-pkg-config}"
PKG_CONFIG_FILTER="$PWD/pkg-config-mesa-filter.sh"
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
    expat
    libdrm
    libglvnd
    wayland-client
    wayland-server
    wayland-egl-backend
    x11
    x11-xcb
    xcb-dri2
    xcb-dri3
    xcb-glx
    xcb-present
    xcb-randr
    xcb-shm
    xcb-xfixes
    xext
    xshmfence
    xxf86vm
    zlib
)
for module in "${required_modules[@]}"; do
    if ! pkg-config --exists "$module"; then
        echo "ERROR: Missing required Mesa dependency: $module"
        exit 1
    fi
done

rm -rf build
if [ ! -d "build" ]; then
    meson setup build --prefix=/usr --libdir=lib64 -Dplatforms=x11,wayland -Dgallium-drivers=swrast,virgl -Dvulkan-drivers= -Dopengl=true -Dglx=dri -Degl=enabled -Dgles1=enabled -Dgles2=enabled -Dglvnd=true -Dllvm=disabled -Dshared-glapi=enabled -Dgbm=enabled -Dbuildtype=release -Dwerror=false
fi
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install

rm -f "$PKG_CONFIG_FILTER"

# Manual install of dri_interface.h and dri.pc for xorg-server
# Mesa 20+ stopped installing these, but xorg-server < 21.1 still needs them (and header is still used)
mkdir -p "$ROOTFS/usr/include/GL/internal"
cp include/GL/internal/dri_interface.h "$ROOTFS/usr/include/GL/internal/"

mkdir -p "$ROOTFS/usr/lib64/pkgconfig"
cat <<EOF > "$ROOTFS/usr/lib64/pkgconfig/dri.pc"
prefix=/usr
libdir=\${prefix}/lib64
includedir=\${prefix}/include

Name: dri
Description: Direct Rendering Infrastructure
Version: $MESA_VER
Cflags: -I\${includedir}
EOF
