#!/bin/bash
set -e

GINIT_SRC="$ROOT_DIR/ginit/src"
GINIT_LIB="$ROOT_DIR/ginit/lib"
SRC="$ROOT_DIR/src"
PKGS="$ROOT_DIR/src/packages/system"
TARGET_MULTIARCH="x86_64-linux-gnu"
TARGET_CXX_VERSION="$(find "$ROOTFS/usr/include/c++" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]+$' | sort -V | tail -n1)"
TARGET_COMPILER="${TARGET_CXX:-${CXX:-/usr/bin/g++}}"
TARGET_STRIP_TOOL="${TARGET_STRIP:-strip}"
COMMON_CXXFLAGS=(--sysroot="$ROOTFS" -O2 -I "$GINIT_SRC" -I "$SRC")
COMMON_LDFLAGS=(
    --sysroot="$ROOTFS"
    -L"$GINIT_LIB"
    -L"$ROOTFS/usr/lib/$TARGET_MULTIARCH"
    -L"$ROOTFS/lib/$TARGET_MULTIARCH"
    -Wl,-rpath-link,"$ROOTFS/usr/lib/$TARGET_MULTIARCH"
    -Wl,-rpath-link,"$ROOTFS/lib/$TARGET_MULTIARCH"
)
COMMON_LIBS=(-lgemcore -lssl -lcrypto -lz -lzstd -ldl -lpthread -lcrypt)

if [ -n "$TARGET_CXX_VERSION" ]; then
    COMMON_CXXFLAGS+=(
        -nostdinc++
        -isystem "$ROOTFS/usr/include/c++/$TARGET_CXX_VERSION"
        -isystem "$ROOTFS/usr/include/$TARGET_MULTIARCH/c++/$TARGET_CXX_VERSION"
        -isystem "$ROOTFS/usr/include/c++/$TARGET_CXX_VERSION/backward"
    )
fi

build_tool() {
    local output="$1"
    shift
    "$TARGET_COMPILER" "${COMMON_CXXFLAGS[@]}" -o "$output" "$@" "${COMMON_LDFLAGS[@]}" "${COMMON_LIBS[@]}"
    "$TARGET_STRIP_TOOL" "$output"
}

echo "Removing staged gpkg runtimes..."
rm -f "$ROOTFS/bin/apps/system/gpkg-v2" \
      "$ROOTFS/bin/apps/system/gpkg-v2-worker" \
      "$ROOTFS/bin/gpkg-v2" \
      "$ROOTFS/bin/gpkg-v2-worker" \
      "$ROOTFS/usr/bin/gpkg-v2" \
      "$ROOTFS/usr/bin/gpkg-v2-worker"

echo "Compiling ping..."
build_tool "$ROOTFS/bin/apps/system/ping" "$PKGS/ping/ping.cpp"

echo "Compiling greq..."
build_tool "$ROOTFS/bin/apps/system/greq" "$PKGS/greq/greq.cpp"

echo "Compiling User Tools..."
build_tool "$ROOTFS/bin/apps/system/su" "$PKGS/su/su.cpp"

# The Debian-backed adduser/passwd ports now provide the canonical account
# management frontends. Keep the old GeminiOS implementations out of the
# staged image so PATH resolution always reaches the real tools.
rm -f "$ROOTFS/bin/apps/system/adduser" \
      "$ROOTFS/bin/apps/system/passwd" \
      "$ROOTFS/bin/apps/system/useradd" \
      "$ROOTFS/bin/apps/system/userdel" \
      "$ROOTFS/bin/apps/system/usermod"

echo "Compiling Installer..."
build_tool "$ROOTFS/bin/apps/system/installer" "$PKGS/installer/"*.cpp
