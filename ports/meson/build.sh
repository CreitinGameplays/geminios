#!/bin/bash
set -e
MESON_VER="1.3.1"
download_and_extract "https://github.com/mesonbuild/meson/releases/download/$MESON_VER/meson-$MESON_VER.tar.gz" "meson-$MESON_VER.tar.gz" "meson-$MESON_VER"
cd "$DEP_DIR/meson-$MESON_VER"

# We use the target python (via wrapper) to install meson
# This ensures we use Python 3.11 with all modules (like pipes) available
"$HOME/.pyenv/versions/3.11.9/bin/python3" setup.py install --prefix=/usr --root="$ROOTFS"

# Fix meson script to work on both host (during build) and target
cat > "$ROOTFS/usr/bin/meson" <<EOF
#!/usr/bin/env python3
# EASY-INSTALL-ENTRY-SCRIPT: 'meson==1.3.1','console_scripts','meson'
import re
import sys
import os

# Add relative path to site-packages to support running from rootfs on host or target
script_dir = os.path.dirname(os.path.realpath(__file__))
# ../lib/python3.11/site-packages
site_pkg = os.path.join(script_dir, '../lib/python3.11/site-packages')
if os.path.exists(site_pkg):
    sys.path.insert(0, site_pkg)

print("DEBUG: sys.path:", sys.path)

# for compatibility with easy_install; see #2198
__requires__ = 'meson==1.3.1'

try:
    from importlib.metadata import distribution
except ImportError:
    try:
        from importlib_metadata import distribution
    except ImportError:
        from pkg_resources import load_entry_point


def importlib_load_entry_point(spec, group, name):
    dist_name, _, _ = spec.partition('==')
    matches = (
        entry_point
        for entry_point in distribution(dist_name).entry_points
        if entry_point.group == group and entry_point.name == name
    )
    return next(matches).load()


globals().setdefault('load_entry_point', importlib_load_entry_point)


if __name__ == '__main__':
    sys.argv[0] = re.sub(r'(-script\.pyw?|\.exe)?$', '', sys.argv[0])
    sys.exit(load_entry_point('meson==1.3.1', 'console_scripts', 'meson')())
EOF
chmod 755 "$ROOTFS/usr/bin/meson"

