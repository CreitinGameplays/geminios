#!/bin/bash

# GeminiOS Global Build Configuration
export ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEP_DIR="$ROOT_DIR/external_dependencies"
export BOOTSTRAP_ROOTFS="$ROOT_DIR/bootstrap_rootfs"
export BUILD_SYSROOT="$ROOT_DIR/build_sysroot"
export FINAL_ROOTFS="$ROOT_DIR/rootfs"
export ROOTFS="$BUILD_SYSROOT"
export LOG_DIR="$ROOT_DIR/logs"
export OUTPUT_DIR="$ROOT_DIR/output"
export PACKAGES_DIR="$ROOT_DIR/ports"

export KERNEL_VERSION="linux-7.0-rc6"
export KERNEL_SOURCE_URL="https://git.kernel.org/torvalds/t/linux-7.0-rc6.tar.gz"
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
        if [ -f "$DEP_DIR/$archive" ] && [ ! -s "$DEP_DIR/$archive" ]; then
            rm -f "$DEP_DIR/$archive"
        fi
        if [ ! -f "$DEP_DIR/$archive" ]; then
            wget -q -O "$DEP_DIR/$archive" "$url"
        fi
        if ! tar -xf "$DEP_DIR/$archive" -C "$DEP_DIR"; then
            rm -f "$DEP_DIR/$archive"
            echo "Failed to extract $archive; removed cached archive so the next run can re-download it."
            return 1
        fi
        rm "$DEP_DIR/$archive"
    fi
}
export -f download_and_extract

rootfs_dirs_alias() {
    local left="$1"
    local right="$2"
    [ "$(readlink -m "$left")" = "$(readlink -m "$right")" ]
}
export -f rootfs_dirs_alias

move_rootfs_entry_if_distinct() {
    local src="$1"
    local dst="$2"
    [ -e "$src" ] || return 0
    mkdir -p "$(dirname "$dst")"
    if rootfs_dirs_alias "$(dirname "$src")" "$(dirname "$dst")"; then
        return 0
    fi
    mv -f "$src" "$dst"
}
export -f move_rootfs_entry_if_distinct
