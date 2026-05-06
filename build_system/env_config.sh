#!/bin/bash

# GeminiOS Global Build Configuration
export ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEP_DIR="${GEMINIOS_EXTERNAL_DEPENDENCIES_DIR:-$ROOT_DIR/external_dependencies}"
export BOOTSTRAP_ROOTFS="$ROOT_DIR/bootstrap_rootfs"
export BUILD_SYSROOT="$ROOT_DIR/build_sysroot"
export FINAL_ROOTFS="$ROOT_DIR/rootfs"
export ROOTFS="$BUILD_SYSROOT"
export LOG_DIR="$ROOT_DIR/logs"
export OUTPUT_DIR="$ROOT_DIR/output"
export PACKAGES_DIR="$ROOT_DIR/ports"
export PATH="$ROOT_DIR/build_system/wrap_bin:$ROOT_DIR/build_system/shim:$PATH"

export KERNEL_VERSION="linux-7.0-rc5"
export KERNEL_SOURCE_URL="https://git.kernel.org/torvalds/t/linux-7.0-rc6.tar.gz"
export KERNEL_BZIMAGE="$DEP_DIR/$KERNEL_VERSION/arch/x86/boot/bzImage"
export JOBS=${JOBS:-$(nproc)}

configure_gdk_pixbuf_loader_env() {
    local pixbuf_root="${ROOTFS:-$BUILD_SYSROOT}/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0"
    local pixbuf_module_dir="$pixbuf_root/loaders"
    local pixbuf_cache_file="$pixbuf_root/loaders.cache"

    if [ -d "$pixbuf_module_dir" ]; then
        export GDK_PIXBUF_MODULEDIR="$pixbuf_module_dir"
    else
        unset GDK_PIXBUF_MODULEDIR
    fi

    if [ -f "$pixbuf_cache_file" ]; then
        export GDK_PIXBUF_MODULE_FILE="$pixbuf_cache_file"
    else
        unset GDK_PIXBUF_MODULE_FILE
    fi
}
export -f configure_gdk_pixbuf_loader_env

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

    normalize_autotools_generated_timestamps "$DEP_DIR/$dirname"
}
export -f download_and_extract

normalize_autotools_generated_timestamps() {
    local src_dir="$1"
    local sources=()
    local generated=()
    local path=""
    local needs_normalization=0

    [ -d "$src_dir" ] || return 0

    while IFS= read -r path; do
        sources+=("$path")
    done < <(
        find "$src_dir" -type f \
            \( -name configure.ac -o -name configure.in -o -name acinclude.m4 -o -name '*.m4' -o -name Makefile.am -o -name Makemodule.am \) \
            | sort
    )

    if [ ${#sources[@]} -eq 0 ]; then
        return 0
    fi

    while IFS= read -r path; do
        generated+=("$path")
    done < <(
        find "$src_dir" -type f \
            \( -name aclocal.m4 -o -name configure -o -name config.h.in -o -name Makefile.in \) \
            | sort
    )

    [ ${#generated[@]} -gt 0 ] || return 0

    for path in "${generated[@]}"; do
        local source=""
        for source in "${sources[@]}"; do
            if [ "$path" -ot "$source" ]; then
                needs_normalization=1
                break 2
            fi
        done
    done

    [ "$needs_normalization" -eq 1 ] || return 0

    echo "[*] Normalizing autotools-generated timestamps in $(basename "$src_dir")..."
    touch "${generated[@]}"
}
export -f normalize_autotools_generated_timestamps

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

normalize_ncurses_runtime_aliases() {
    local root_dir="${1:-$ROOTFS}"
    local canonical_dir="$root_dir/usr/lib/x86_64-linux-gnu"

    [ -d "$canonical_dir" ] || return 0

    local lib
    for lib in ncurses form panel menu tinfo; do
        local fallback_name="lib${lib}w.so.6"
        local fallback_path="$canonical_dir/$fallback_name"
        [ -e "$fallback_path" ] || continue

        # Keep the wide runtime SONAMEs as the single source of truth.
        ln -sfn "$fallback_name" "$canonical_dir/lib${lib}.so.6"
        ln -sfn "$fallback_name" "$canonical_dir/lib${lib}.so"
    done
}
export -f normalize_ncurses_runtime_aliases

prune_autotools_build_tree() {
    local src_dir="$1"

    [ -d "$src_dir" ] || return 0

    if [ -f "$src_dir/Makefile" ]; then
        make -C "$src_dir" distclean >/dev/null 2>&1 || true
    fi

    rm -f \
        "$src_dir/config.cache" \
        "$src_dir/config.log" \
        "$src_dir/config.status" \
        "$src_dir/libtool"

    find "$src_dir" -type d -name .libs -prune -exec rm -rf {} +
    find "$src_dir" -type f \( \
        -name '*.o' -o \
        -name '*.lo' -o \
        -name '*.la' -o \
        -name '*.a' -o \
        -name '*.so' -o \
        -name '*.so.*' \
    \) -delete
}
export -f prune_autotools_build_tree

configure_gdk_pixbuf_loader_env
