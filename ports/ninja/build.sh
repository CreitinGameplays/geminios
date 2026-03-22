#!/bin/bash
set -e
NINJA_VER="1.11.1"
download_and_extract "https://github.com/ninja-build/ninja/archive/v$NINJA_VER.tar.gz" "ninja-$NINJA_VER.tar.gz" "ninja-$NINJA_VER"
cd "$DEP_DIR/ninja-$NINJA_VER"

# Build the bootstrap ninja binary with the host toolchain defaults. Pointing
# its link step at both staged glibc library directories can trigger the same
# GLIBC_PRIVATE linker failure seen in autoconf sanity checks.
"$HOME/.pyenv/versions/3.11.9/bin/python3" configure.py

# Build using host ninja
/usr/bin/ninja

install -Dm755 ninja "$ROOTFS/usr/bin/ninja"
