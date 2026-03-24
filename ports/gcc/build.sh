#!/bin/bash
set -e

echo "Validating staged Debian GCC toolchain..."

required_paths=(
    "$ROOTFS/usr/bin/gcc"
    "$ROOTFS/usr/bin/g++"
    "$ROOTFS/usr/bin/cpp"
    "$ROOTFS/usr/lib/x86_64-linux-gnu/libgcc_s.so.1"
    "$ROOTFS/usr/lib/x86_64-linux-gnu/libstdc++.so.6"
)

cc1_path=""
cc1_manifest_path="$ROOTFS/usr/libexec/gcc/x86_64-linux-gnu/14/cc1"
for candidate in \
    "$cc1_manifest_path" \
    "$ROOTFS/usr/lib/gcc/x86_64-linux-gnu/14/cc1"
do
    if [ -x "$candidate" ]; then
        cc1_path="$candidate"
        break
    fi
done

if [ -z "$cc1_path" ]; then
    echo "Missing staged GCC internal compiler (cc1) in $ROOTFS"
    exit 1
fi

for path in "${required_paths[@]}"; do
    if [ ! -e "$path" ]; then
        echo "Missing staged GCC artifact: $path"
        exit 1
    fi
done

install -d "$ROOTFS/usr/bin"
ln -sf gcc "$ROOTFS/usr/bin/cc"

if [ "$cc1_path" != "$cc1_manifest_path" ]; then
    install -d "$(dirname "$cc1_manifest_path")"
    ln -sf "../../../../lib/gcc/x86_64-linux-gnu/14/cc1" "$cc1_manifest_path"
fi

if [ -x "$ROOTFS/usr/bin/gcc" ]; then
    "$ROOTFS/usr/bin/gcc" --version >/dev/null 2>&1 || true
fi

echo "Staged Debian GCC toolchain is present and ready."
