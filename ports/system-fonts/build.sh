#!/bin/bash
set -e

FONT_VER="4.1"
FONT_URL="https://github.com/rsms/inter/releases/download/v${FONT_VER}/Inter-${FONT_VER}.zip"
FONT_DIR="Inter-${FONT_VER}"

# Download
if [ ! -f "$DEP_DIR/Inter-${FONT_VER}.zip" ]; then
    wget -q -O "$DEP_DIR/Inter-${FONT_VER}.zip" "$FONT_URL"
fi

# Extract
mkdir -p "$DEP_DIR/$FONT_DIR"
unzip -q -o "$DEP_DIR/Inter-${FONT_VER}.zip" -d "$DEP_DIR/$FONT_DIR"

# Install
mkdir -p "$ROOTFS/usr/share/fonts/TTF"
find "$DEP_DIR/$FONT_DIR" -name "*.ttf" -exec cp {} "$ROOTFS/usr/share/fonts/TTF/" \;
find "$DEP_DIR/$FONT_DIR" -name "*.otf" -exec cp {} "$ROOTFS/usr/share/fonts/TTF/" \;

# Clean up
rm -rf "$DEP_DIR/$FONT_DIR"
