#!/bin/bash
# GeminiOS Target Environment (Apply after Glibc)
TARGET_SYSROOT="${TARGET_SYSROOT:-${BUILD_SYSROOT:-$ROOTFS}}"
FINAL_ROOTFS="${FINAL_ROOTFS:-$ROOTFS}"

export BUILD_CC="/usr/bin/gcc"
export BUILD_CXX="/usr/bin/g++"
export BUILD_AR="/usr/bin/ar"
export BUILD_RANLIB="/usr/bin/ranlib"
export BUILD_PKG_CONFIG="/usr/bin/pkg-config"

export TARGET_CC="x86_64-gemini-linux-gnu-gcc"
export TARGET_CXX="x86_64-gemini-linux-gnu-g++"
export TARGET_AR="x86_64-gemini-linux-gnu-ar"
export TARGET_RANLIB="x86_64-gemini-linux-gnu-ranlib"
export TARGET_READELF="x86_64-gemini-linux-gnu-readelf"
export TARGET_OBJDUMP="x86_64-gemini-linux-gnu-objdump"
export TARGET_STRIP="x86_64-gemini-linux-gnu-strip"
export TARGET_PKG_CONFIG="$ROOT_DIR/build_system/wrap_bin/pkg-config"
export TARGET_SYSROOT

export CC="$TARGET_CC"
export CXX="$TARGET_CXX"
export AR="$TARGET_AR"
export RANLIB="$TARGET_RANLIB"

# Keep the shared target flags conservative. Some configure scripts
# intentionally abort if they detect any Werror-related flag, including
# -Wno-error, so warning policy stays package-local when needed.
export CFLAGS="--sysroot=$TARGET_SYSROOT -O2 -fPIC"
export CXXFLAGS="--sysroot=$TARGET_SYSROOT -O2 -fPIC"
# Prefer the staged linker-script directory only. Adding legacy lib64
# makes autoconf sanity checks bypass libc.so's linker script, which can fail
# early with GLIBC_PRIVATE references from the staged libc.so.6.
export LDFLAGS="--sysroot=$TARGET_SYSROOT -L$TARGET_SYSROOT/usr/lib/x86_64-linux-gnu -L$TARGET_SYSROOT/lib/x86_64-linux-gnu"
# Teach libtool that the staged multiarch library directories are the target's
# default search paths. Without this, libtool-based ports can bake the host
# build_sysroot path into RUNPATH entries for installed shared libraries.
export lt_cv_sys_lib_search_path_spec="$TARGET_SYSROOT/usr/lib/x86_64-linux-gnu $TARGET_SYSROOT/lib/x86_64-linux-gnu"
export lt_cv_sys_lib_dlsearch_path_spec="$TARGET_SYSROOT/usr/lib/x86_64-linux-gnu $TARGET_SYSROOT/lib/x86_64-linux-gnu"
export PKG_CONFIG_LIBDIR="$TARGET_SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig:$TARGET_SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$TARGET_SYSROOT"

# Python specific - Use the wrapper for the built python
export TARGET_PYTHON="$ROOT_DIR/build_system/run_target_python.sh"

# Paths
export PATH="$ROOT_DIR/build_system/wrap_bin:$ROOT_DIR/build_system/shim:$PATH:$TARGET_SYSROOT/usr/bin:$TARGET_SYSROOT/bin"
export PKG_CONFIG_PATH="$TARGET_SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig:$TARGET_SYSROOT/usr/share/pkgconfig"
