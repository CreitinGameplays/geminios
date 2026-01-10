#!/bin/bash
set -e
NINJA_VER="1.11.1"
download_and_extract "https://github.com/ninja-build/ninja/archive/v$NINJA_VER.tar.gz" "ninja-$NINJA_VER.tar.gz" "ninja-$NINJA_VER"
cd "$DEP_DIR/ninja-$NINJA_VER"

# Use host python to generate build.ninja
export LDFLAGS="$LDFLAGS -L$ROOTFS/usr/lib64 -L$ROOTFS/lib64"
export CXXFLAGS="$CXXFLAGS -L$ROOTFS/usr/lib64 -L$ROOTFS/lib64"
"$HOME/.pyenv/versions/3.11.9/bin/python3" configure.py

# Build using host ninja
/usr/bin/ninja

install -Dm755 ninja "$ROOTFS/usr/bin/ninja"
