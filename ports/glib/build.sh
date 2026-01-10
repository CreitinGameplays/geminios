#!/bin/bash
set -e

GLIB_VER="2.78.3"
download_and_extract "https://download.gnome.org/sources/glib/2.78/glib-$GLIB_VER.tar.xz" "glib-$GLIB_VER.tar.xz" "glib-$GLIB_VER"

cd "$DEP_DIR/glib-$GLIB_VER"

OLD_PYTHONHOME=$PYTHONHOME
unset PYTHONHOME

rm -rf build
meson setup build --prefix=/usr --libdir=lib64 \
    -Ddefault_library=shared \
    -Dselinux=disabled \
    -Dlibmount=disabled \
    -Dtests=false \
    -Dwerror=false
    
ninja -v -C build
DESTDIR="$ROOTFS" ninja -C build install

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

