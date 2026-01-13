#!/bin/bash
set -e

# Default values if not set
ROOT_DIR="${ROOT_DIR:-$(pwd)}"
ROOTFS="${ROOTFS:-$ROOT_DIR/rootfs}"
JOBS="${JOBS:-1}"

compile_sys_pkg() {
    PKG=$1
    echo "Compiling system package: $PKG"
    g++ -static -O2 -I "$ROOT_DIR/src" -o "$ROOTFS/bin/apps/system/$PKG" "$ROOT_DIR/packages/system/$PKG/$PKG.cpp"
    strip "$ROOTFS/bin/apps/system/$PKG"
}

mkdir -p "$ROOTFS/bin/apps/system"

for pkg in gtop poweroff reboot snake; do
    compile_sys_pkg $pkg &
    if [[ $(jobs -r -p | wc -l) -ge $JOBS ]]; then
        wait -n
    fi
done
wait
