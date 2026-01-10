#!/bin/bash
set -e

# Use host GCC instead of compiling
# This saves significant time but requires host glibc compatibility

echo "Copying Host GCC..."

HOST_GCC=$(which gcc)
HOST_GXX=$(which g++)
HOST_CC1=$(gcc -print-prog-name=cc1)
HOST_CC1PLUS=$(gcc -print-prog-name=cc1plus)
HOST_CPP=$(which cpp)

# 1. Install Libraries (GMP, MPC, MPFR, ISL, ZSTD) required by cc1
# We use ldd to find the specific paths on the host
echo "Resolving dependencies for cc1..."
DEPS=$(ldd "$HOST_CC1" | grep "=> /" | awk '{print $3}')
for lib in $DEPS; do
    libname=$(basename "$lib")
    # Skip libc, libm, ld-linux, libdl as they are provided by glibc package
    if [[ "$libname" == libc.so* || "$libname" == libm.so* || "$libname" == ld-linux* || "$libname" == libdl.so* || "$libname" == libpthread* ]]; then
        continue
    fi
    
    echo "  Copying $libname..."
    cp -L "$lib" "$ROOTFS/usr/lib64/$libname"
done

# 2. Install Binaries
echo "Installing binaries..."
install -Dm755 "$HOST_GCC" "$ROOTFS/usr/bin/gcc"
install -Dm755 "$HOST_GXX" "$ROOTFS/usr/bin/g++"
install -Dm755 "$HOST_CPP" "$ROOTFS/usr/bin/cpp"
ln -sf gcc "$ROOTFS/usr/bin/cc"

# 3. Install Internal Components (cc1, cc1plus)
# We replicate the internal path structure (e.g. /usr/libexec/gcc/x86_64-linux-gnu/14/)
HOST_CC1_DIR=$(dirname "$HOST_CC1")
# Determine relative path from root
# Assuming HOST_CC1 is like /usr/libexec/...
if [[ "$HOST_CC1" == /usr/* ]]; then
    REL_DIR=${HOST_CC1_DIR#/usr/}
    TARGET_DIR="$ROOTFS/usr/$REL_DIR"
else
    # Fallback or weird location
    REL_DIR=${HOST_CC1_DIR#/}
    TARGET_DIR="$ROOTFS/$REL_DIR"
fi

mkdir -p "$TARGET_DIR"
install -Dm755 "$HOST_CC1" "$TARGET_DIR/cc1"
install -Dm755 "$HOST_CC1PLUS" "$TARGET_DIR/cc1plus"

# 4. Install Internal Headers
# Used for compiling (stdarg.h, etc.)
HOST_INCLUDE_DIR=$(gcc -print-file-name=include)
HOST_INCLUDE_FIXED_DIR=$(gcc -print-file-name=include-fixed)

# Use the same relative structure as the binaries (usually ../lib/gcc/...)
# Or we can just copy them to the location corresponding to the host path
if [[ "$HOST_INCLUDE_DIR" == /usr/* ]]; then
    REL_INC_DIR=${HOST_INCLUDE_DIR#/usr/}
    TARGET_INC_DIR="$ROOTFS/usr/$REL_INC_DIR"
else
    TARGET_INC_DIR="$ROOTFS/usr/lib64/gcc/include"
fi

mkdir -p "$(dirname "$TARGET_INC_DIR")"
cp -r "$HOST_INCLUDE_DIR" "$TARGET_INC_DIR"

if [ -d "$HOST_INCLUDE_FIXED_DIR" ]; then
    cp -r "$HOST_INCLUDE_FIXED_DIR" "$(dirname "$TARGET_INC_DIR")/include-fixed"
fi

echo "Host GCC installed successfully."
