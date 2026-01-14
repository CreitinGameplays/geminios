#!/bin/bash
set -e

GINIT_SRC="$ROOT_DIR/ginit/src"
GINIT_LIB="$ROOT_DIR/ginit/lib"
SRC="$ROOT_DIR/src"
PKGS="$ROOT_DIR/packages/system"

echo "Compiling gpkg-worker..."
g++ $CXXFLAGS -o "$ROOTFS/bin/apps/system/gpkg-worker" "$PKGS/gpkg/gpkg_worker.cpp" -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip "$ROOTFS/bin/apps/system/gpkg-worker"

echo "Compiling gpkg..."
g++ $CXXFLAGS -I "$GINIT_SRC" -I "$SRC" -o "$ROOTFS/bin/apps/system/gpkg" "$PKGS/gpkg/gpkg.cpp" -L"$GINIT_LIB" -lgemcore -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip "$ROOTFS/bin/apps/system/gpkg"

echo "Compiling ping..."
g++ $CXXFLAGS -I "$GINIT_SRC" -I "$SRC" -o "$ROOTFS/bin/apps/system/ping" "$PKGS/ping/ping.cpp" -L"$GINIT_LIB" -lgemcore -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip "$ROOTFS/bin/apps/system/ping"

echo "Compiling greq..."
g++ $CXXFLAGS -I "$GINIT_SRC" -I "$SRC" -o "$ROOTFS/bin/apps/system/greq" "$PKGS/greq/greq.cpp" -L"$GINIT_LIB" -lgemcore -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip "$ROOTFS/bin/apps/system/greq"

echo "Compiling User Tools..."
for tool in passwd adduser useradd userdel usermod su sudo; do
    g++ $CXXFLAGS -I "$GINIT_SRC" -I "$SRC" -o "$ROOTFS/bin/apps/system/$tool" "$PKGS/$tool/$tool.cpp" -L"$GINIT_LIB" -lgemcore -lssl -lcrypto -lz -lzstd -ldl -lpthread
    strip "$ROOTFS/bin/apps/system/$tool"
done

echo "Compiling Installer..."
g++ $CXXFLAGS -I "$GINIT_SRC" -I "$SRC" -o "$ROOTFS/bin/apps/system/installer" "$PKGS/installer/installer.cpp" -L"$GINIT_LIB" -lgemcore -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip "$ROOTFS/bin/apps/system/installer"
