#!/bin/bash
set -e

GIR_VER="1.78.1"
download_and_extract "https://download.gnome.org/sources/gobject-introspection/1.78/gobject-introspection-$GIR_VER.tar.xz" "gobject-introspection-$GIR_VER.tar.xz" "gobject-introspection-$GIR_VER"

cd "$DEP_DIR/gobject-introspection-$GIR_VER"

# Apply patch to fix missing distutils.msvccompiler on Linux with Python 3.11+
# Check if patch is already applied
if ! grep -q "try:" giscanner/ccompiler.py; then
    echo "Applying gobject-introspection-1.78.1-msvc.patch..."
    patch -p0 < "$ROOT_DIR/patches/gobject-introspection-1.78.1-msvc.patch"
else
    echo "Patch gobject-introspection-1.78.1-msvc.patch already applied."
fi

# Unset PYTHONHOME to avoid conflicts with host python
unset PYTHONHOME

# Meson probes the configured interpreter very early and expects a fully working
# distutils-capable Python. Running the staged target interpreter here is brittle
# because the rootfs libc/runtime may not be self-consistent yet. Use a host-side
# Python 3.11 instead so the build ABI matches the target Python package without
# executing partially staged target binaries during configure.
BUILD_PYTHON="${TARGET_BUILD_PYTHON:-$HOME/.pyenv/versions/3.11.9/bin/python3.11}"
if [ ! -x "$BUILD_PYTHON" ]; then
    BUILD_PYTHON="$(command -v python3.11 || true)"
fi
if [ -z "$BUILD_PYTHON" ] || [ ! -x "$BUILD_PYTHON" ]; then
    echo "ERROR: Python 3.11 build interpreter not found. Set TARGET_BUILD_PYTHON." >&2
    exit 1
fi

# Create a local bin directory to expose the selected interpreter as 'python3'
mkdir -p local_bin
ln -sf "$BUILD_PYTHON" local_bin/python3

# Configure pkg-config to look into rootfs
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig:$ROOTFS/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"
export XDG_CACHE_HOME="$(pwd)/.cache"
mkdir -p "$XDG_CACHE_HOME"

# Prepend local_bin to PATH so 'env python3' (used by g-ir-scanner) finds the
# same interpreter Meson configured with.
# We do NOT add rootfs/usr/bin to PATH to ensure we don't shadow other host tools (like meson).
# Host meson uses /usr/bin/python3 (absolute), so it is unaffected by PATH.
export PATH="$(pwd)/local_bin:$PATH"

rm -rf build

# Run meson pointing to the host-side Python 3.11 interpreter.
meson setup build --prefix=/usr --libdir=lib/x86_64-linux-gnu \
    -Dpython="$BUILD_PYTHON" \
    -Ddoctool=disabled \
    -Dwerror=false

ninja -C build
DESTDIR="$ROOTFS" ninja -C build install

# FIX: Rename _giscanner.cpython-*.so to _giscanner.so so python can import it simply as 'import _giscanner'
# This is required because g-ir-scanner seems to expect the simple name or there's a mismatch in extension lookup.
echo "Renaming _giscanner shared object..."
find "$ROOTFS/usr/lib/x86_64-linux-gnu/gobject-introspection/giscanner" -name "_giscanner.cpython-*.so" -exec sh -c 'mv "$1" "${1%.cpython-*.so}.so"' _ {} \;
