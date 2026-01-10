#!/bin/bash
set -e
VER="1.3.2"
download_and_extract "https://files.pythonhosted.org/packages/source/M/Mako/Mako-$VER.tar.gz" "Mako-$VER.tar.gz" "Mako-$VER"
cd "$DEP_DIR/Mako-$VER"

"$TARGET_PYTHON" setup.py install --prefix=/usr --root="$ROOTFS"
