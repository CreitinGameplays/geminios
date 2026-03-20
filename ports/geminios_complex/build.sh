#!/bin/bash
set -e

GINIT_SRC="$ROOT_DIR/ginit/src"
GINIT_LIB="$ROOT_DIR/ginit/lib"
SRC="$ROOT_DIR/src"
PKGS="$ROOT_DIR/packages/system"
GPKG_DIR="$ROOT_DIR/gpkg"

# Build these C++ userspace tools with the host toolchain. The target sysroot
# is not yet complete enough for libstdc++/pthread-heavy binaries like gpkg.
unset CFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_PATH

echo "Compiling gpkg module..."
make -C "$GPKG_DIR" clean
make -C "$GPKG_DIR" install DESTDIR="$ROOTFS"

echo "Compiling ping..."
/usr/bin/g++ -I "$GINIT_SRC" -I "$SRC" -o "$ROOTFS/bin/apps/system/ping" "$PKGS/ping/ping.cpp" -L"$GINIT_LIB" -lgemcore -lssl -lcrypto -lz -lzstd -ldl -lpthread -lcrypt
/usr/bin/strip "$ROOTFS/bin/apps/system/ping"

echo "Compiling greq..."
/usr/bin/g++ -I "$GINIT_SRC" -I "$SRC" -o "$ROOTFS/bin/apps/system/greq" "$PKGS/greq/greq.cpp" -L"$GINIT_LIB" -lgemcore -lssl -lcrypto -lz -lzstd -ldl -lpthread -lcrypt
/usr/bin/strip "$ROOTFS/bin/apps/system/greq"

echo "Compiling User Tools..."
for tool in passwd adduser useradd userdel usermod su sudo; do
    /usr/bin/g++ -I "$GINIT_SRC" -I "$SRC" -o "$ROOTFS/bin/apps/system/$tool" "$PKGS/$tool/$tool.cpp" -L"$GINIT_LIB" -lgemcore -lssl -lcrypto -lz -lzstd -ldl -lpthread -lcrypt
    /usr/bin/strip "$ROOTFS/bin/apps/system/$tool"
done

echo "Compiling Installer..."
/usr/bin/g++ -I "$GINIT_SRC" -I "$SRC" -o "$ROOTFS/bin/apps/system/installer" "$PKGS/installer/installer.cpp" -L"$GINIT_LIB" -lgemcore -lssl -lcrypto -lz -lzstd -ldl -lpthread -lcrypt
/usr/bin/strip "$ROOTFS/bin/apps/system/installer"
