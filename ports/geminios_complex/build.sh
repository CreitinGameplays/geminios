#!/bin/bash
set -e

GINIT_SRC="$ROOT_DIR/ginit/src"
GINIT_LIB="$ROOT_DIR/ginit/lib"
SRC="$ROOT_DIR/src"
PKGS="$ROOT_DIR/src/packages/system"
GPKG_DIR="$ROOT_DIR/gpkg"
TARGET_MULTIARCH="x86_64-linux-gnu"
TARGET_CXX_VERSION="$(find "$ROOTFS/usr/include/c++" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]+$' | sort -V | tail -n1)"
MAKE_JOBS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
COMMON_CXXFLAGS=(--sysroot="$ROOTFS" -O2 -I "$GINIT_SRC" -I "$SRC")
COMMON_LDFLAGS=(--sysroot="$ROOTFS" -L"$GINIT_LIB" -L"$ROOTFS/usr/lib/$TARGET_MULTIARCH" -L"$ROOTFS/lib/$TARGET_MULTIARCH")
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
    /usr/bin/g++ "${COMMON_CXXFLAGS[@]}" -o "$output" "$@" "${COMMON_LDFLAGS[@]}" "${COMMON_LIBS[@]}"
    /usr/bin/strip "$output"
}

echo "Compiling gpkg module..."
make -C "$GPKG_DIR" clean
make -j"$MAKE_JOBS" -C "$GPKG_DIR" install DESTDIR="$ROOTFS" ROOTFS="$ROOTFS" CXXFLAGS="${COMMON_CXXFLAGS[*]}" LDFLAGS="${COMMON_LDFLAGS[*]}"

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
