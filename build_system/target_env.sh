#!/bin/bash
# GeminiOS Target Environment (Apply after Glibc)
export CFLAGS="--sysroot=$ROOTFS -O2 -fPIC -Wno-error"
export CXXFLAGS="--sysroot=$ROOTFS -O2 -fPIC -Wno-error"
# Prefer the staged linker-script directory only. Adding legacy lib64
# makes autoconf sanity checks bypass libc.so's linker script, which can fail
# early with GLIBC_PRIVATE references from the staged libc.so.6.
export LDFLAGS="--sysroot=$ROOTFS -L$ROOTFS/usr/lib/x86_64-linux-gnu"
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig:$ROOTFS/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"

# Python specific - Use the wrapper for the built python
export TARGET_PYTHON="$ROOT_DIR/build_system/run_target_python.sh"

# Paths
export PATH="$ROOT_DIR/build_system/wrap_bin:$ROOT_DIR/build_system/shim:$PATH:$ROOTFS/usr/bin:$ROOTFS/bin"
export PKG_CONFIG_PATH="$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig:$ROOTFS/usr/share/pkgconfig"
