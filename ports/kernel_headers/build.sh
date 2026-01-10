#!/bin/bash
set -e

echo "Installing Kernel Headers..."
if [ -d "$DEP_DIR/$KERNEL_VERSION" ]; then
    mkdir -p "$ROOTFS/usr/include"
    cd "$DEP_DIR/$KERNEL_VERSION"
    make headers_install ARCH=x86_64 INSTALL_HDR_PATH="$ROOTFS/usr"
else
    echo "ERROR: Kernel source not found at $DEP_DIR/$KERNEL_VERSION"
    exit 1
fi
