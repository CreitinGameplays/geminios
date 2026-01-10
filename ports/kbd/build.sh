#!/bin/bash
set -e
KBD_VER="2.6.4"
download_and_extract "https://cdn.kernel.org/pub/linux/utils/kbd/kbd-$KBD_VER.tar.xz" "kbd-$KBD_VER.tar.xz" "kbd-$KBD_VER"
# KBD in build_old was used for keymaps. 
# We'll just install data.
mkdir -p "$ROOTFS/usr/share/keymaps"
find "$DEP_DIR/kbd-$KBD_VER/data/keymaps" -name "*.map" -o -name "*.map.gz" | while read mapfile; do
    NAME=$(basename "$mapfile" .gz)
    NAME=$(basename "$NAME" .map)
    loadkeys -b "$mapfile" > "$ROOTFS/usr/share/keymaps/$NAME.bmap" 2>/dev/null || true
done
