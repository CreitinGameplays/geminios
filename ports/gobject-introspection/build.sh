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

# Create a wrapper for the target python that uses the target loader and libraries
# This is crucial to avoid ABI mismatches (segfaults) when running target binaries on host.
cat <<EOF > target_python_wrapper.sh
#!/bin/bash
export PYTHONHOME="$ROOTFS/usr"
LOADER="$ROOTFS/lib64/ld-linux-x86-64.so.2"
LIBRARY_PATH="$ROOTFS/usr/lib64:$ROOTFS/usr/lib:$ROOTFS/lib64"
exec "\$LOADER" --library-path "\$LIBRARY_PATH" "$ROOTFS/usr/bin/python3" "\$@"
EOF
chmod +x target_python_wrapper.sh

# Create a local bin directory to expose the wrapper as 'python3'
mkdir -p local_bin
ln -sf "$(pwd)/target_python_wrapper.sh" local_bin/python3

# Configure pkg-config to look into rootfs
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib64/pkgconfig:$ROOTFS/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"

# Prepend local_bin to PATH so 'env python3' (used by g-ir-scanner) finds our wrapper.
# We do NOT add rootfs/usr/bin to PATH to ensure we don't shadow other host tools (like meson).
# Host meson uses /usr/bin/python3 (absolute), so it is unaffected by PATH.
export PATH="$(pwd)/local_bin:$PATH"

rm -rf build

# Run meson pointing to our python wrapper.
meson setup build --prefix=/usr --libdir=lib64 \
    -Dpython="$(pwd)/target_python_wrapper.sh" \
    -Ddoctool=disabled \
    -Dwerror=false

ninja -C build
DESTDIR="$ROOTFS" ninja -C build install

# FIX: Rename _giscanner.cpython-*.so to _giscanner.so so python can import it simply as 'import _giscanner'
# This is required because g-ir-scanner seems to expect the simple name or there's a mismatch in extension lookup.
echo "Renaming _giscanner shared object..."
find "$ROOTFS/usr/lib64/gobject-introspection/giscanner" -name "_giscanner.cpython-*.so" -exec sh -c 'mv "$1" "${1%.cpython-*.so}.so"' _ {} \;
