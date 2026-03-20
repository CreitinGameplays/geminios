#!/bin/bash
set -e

GLIB_VER="2.84.4"
download_and_extract "https://download.gnome.org/sources/glib/2.84/glib-$GLIB_VER.tar.xz" "glib-$GLIB_VER.tar.xz" "glib-$GLIB_VER"

cd "$DEP_DIR/glib-$GLIB_VER"

OLD_PYTHONHOME=$PYTHONHOME
unset PYTHONHOME

# Build GLib with the host compiler, while resolving GeminiOS deps from the
# staged rootfs. Meson's native sanity checks break if we point the compiler
# at the in-progress sysroot libc directly.
export CC="${CC:-cc}"
export CXX="${CXX:-c++}"
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib64/pkgconfig:$ROOTFS/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"
export CFLAGS="-O2 -fPIC -Wno-error"
export CXXFLAGS="-O2 -fPIC -Wno-error"
export LDFLAGS=""

PKG_CONFIG_REAL="${PKG_CONFIG:-pkg-config}"
PKG_CONFIG_FILTER="$PWD/pkg-config-glib-filter.sh"
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

rm -rf build
meson setup build --prefix=/usr --libdir=lib64 \
    -Ddefault_library=shared \
    -Dselinux=disabled \
    -Dlibmount=disabled \
    -Dtests=false \
    -Dwerror=false
    
ninja -v -C build
DESTDIR="$ROOTFS" ninja -C build install
rm -f "$PKG_CONFIG_FILTER"

# Fix python scripts to work on host (for build) and target
for tool in glib-mkenums glib-genmarshal; do
    if [ -f "$ROOTFS/usr/bin/$tool" ]; then
        # Insert our sys.path fix after 'import sys'
        # We use a temporary file to construct the sed script content
        
        FIX_CODE="
# Add relative path to site-packages to support running from rootfs on host or target
script_dir = os.path.dirname(os.path.realpath(__file__))
# ../lib/python3.11/site-packages
site_pkg = os.path.join(script_dir, '../lib/python3.11/site-packages')
if os.path.exists(site_pkg):
    sys.path.insert(0, site_pkg)
"
        # Use a temporary python script to avoid complex quoting issues
        cat > fix_tool.py <<EOF
import sys
import os

tool_path = "$ROOTFS/usr/bin/$tool"
fix_code = """$FIX_CODE"""

with open(tool_path, 'r') as f:
    lines = f.readlines()

new_lines = []
inserted = False
for line in lines:
    new_lines.append(line)
    if 'import sys' in line and not inserted:
        new_lines.append(fix_code)
        inserted = True

with open(tool_path, 'w') as f:
    f.writelines(new_lines)
EOF
        "$HOME/.pyenv/versions/3.11.9/bin/python3" fix_tool.py
        rm fix_tool.py
        chmod 755 "$ROOTFS/usr/bin/$tool"
    fi
done

export PYTHONHOME=$OLD_PYTHONHOME
