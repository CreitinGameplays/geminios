#!/bin/bash

# GeminiOS Global Build Configuration
export ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEP_DIR="$ROOT_DIR/external_dependencies"
export ROOTFS="$ROOT_DIR/rootfs"
export LOG_DIR="$ROOT_DIR/logs"
export OUTPUT_DIR="$ROOT_DIR/output"
export PACKAGES_DIR="$ROOT_DIR/ports"

export KERNEL_VERSION="linux-6.6.14"
export KERNEL_BZIMAGE="$DEP_DIR/$KERNEL_VERSION/arch/x86/boot/bzImage"
export JOBS=${JOBS:-$(nproc)}

# Helper to download and extract dependencies
download_and_extract() {
    local url="$1"
    local archive="$2"
    local dirname="$3"

    mkdir -p "$DEP_DIR"
    if [ ! -d "$DEP_DIR/$dirname" ]; then
        echo "Downloading and Extracting $dirname..."
        if [ ! -f "$DEP_DIR/$archive" ]; then
            wget -q -O "$DEP_DIR/$archive" "$url"
        fi
        tar -xf "$DEP_DIR/$archive" -C "$DEP_DIR"
        rm "$DEP_DIR/$archive"
    fi
}
export -f download_and_extract