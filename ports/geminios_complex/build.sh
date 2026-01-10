#!/bin/bash
set -e

SRC="$ROOT_DIR/src"
PKGS="$ROOT_DIR/packages/system"

echo "Compiling gpkg..."
g++ $CXXFLAGS -I "$SRC" -o "$ROOTFS/bin/apps/system/gpkg" "$PKGS/gpkg/gpkg.cpp" "$SRC/network.cpp" "$SRC/signals.o" -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip "$ROOTFS/bin/apps/system/gpkg"

echo "Compiling ping..."
g++ $CXXFLAGS -I "$SRC" -o "$ROOTFS/bin/apps/system/ping" "$PKGS/ping/ping.cpp" "$SRC/network.cpp" "$SRC/signals.o" -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip "$ROOTFS/bin/apps/system/ping"

echo "Compiling greq..."
g++ $CXXFLAGS -I "$SRC" -o "$ROOTFS/bin/apps/system/greq" "$PKGS/greq/greq.cpp" "$SRC/network.cpp" "$SRC/signals.o" -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip "$ROOTFS/bin/apps/system/greq"

echo "Compiling User Tools..."
for tool in passwd adduser userdel usermod su sudo; do
    g++ $CXXFLAGS -I "$SRC" -o "$ROOTFS/bin/apps/system/$tool" "$PKGS/$tool/$tool.cpp" "$SRC/user_mgmt.o" -lssl -lcrypto -lz -lzstd -ldl -lpthread
    strip "$ROOTFS/bin/apps/system/$tool"
done

echo "Compiling Installer..."
g++ $CXXFLAGS -I "$SRC" -o "$ROOTFS/bin/apps/system/installer" "$PKGS/installer/installer.cpp" "$SRC/user_mgmt.o" -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip "$ROOTFS/bin/apps/system/installer"
