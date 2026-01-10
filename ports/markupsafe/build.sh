#!/bin/bash
set -e
VER="2.1.5"
download_and_extract "https://files.pythonhosted.org/packages/source/M/MarkupSafe/MarkupSafe-$VER.tar.gz" "MarkupSafe-$VER.tar.gz" "MarkupSafe-$VER"
cd "$DEP_DIR/MarkupSafe-$VER"

"$TARGET_PYTHON" setup.py install --prefix=/usr --root="$ROOTFS"
