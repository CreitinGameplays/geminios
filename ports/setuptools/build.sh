#!/bin/bash
set -e
VER="69.1.0"
download_and_extract "https://files.pythonhosted.org/packages/source/s/setuptools/setuptools-$VER.tar.gz" "setuptools-$VER.tar.gz" "setuptools-$VER"
cd "$DEP_DIR/setuptools-$VER"

"$TARGET_PYTHON" setup.py install --prefix=/usr --root="$ROOTFS"
