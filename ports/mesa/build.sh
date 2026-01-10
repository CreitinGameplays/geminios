#!/bin/bash
set -e
MESA_VER="24.0.0"
download_and_extract "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz" "mesa-$MESA_VER.tar.xz" "mesa-$MESA_VER"
cd "$DEP_DIR/mesa-$MESA_VER"

# Create a shim for python3 to ensure meson uses the wrapper
mkdir -p "$DEP_DIR/bin_shim"
ln -sf "$TARGET_PYTHON" "$DEP_DIR/bin_shim/python3"
export PATH="$DEP_DIR/bin_shim:$PATH"

rm -rf build
if [ ! -d "build" ]; then
    meson setup build --prefix=/usr --libdir=lib64 -Dplatforms=x11 -Dgallium-drivers=swrast,virgl -Dvulkan-drivers= -Dopengl=true -Dglx=dri -Degl=enabled -Dgles1=enabled -Dgles2=enabled -Dllvm=disabled -Dshared-glapi=enabled -Dgbm=enabled -Dbuildtype=release -Dwerror=false
fi
ninja -C build
DESTDIR="$ROOTFS" ninja -C build install

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
