#!/bin/bash
set -e

# Get the directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "--- Building GemFetch v2 ---"

# 1. Compile static binary
# We optimize for size (-Os) and strip symbols
mkdir -p root/bin
g++ -static -Os -o root/bin/gemfetch gemfetch.cpp
strip root/bin/gemfetch

echo "--- Packaging GemFetch v2 ---"

# 2. Build the package using the v2 tool
# We assume we are in packages/user/gemfetch-v2/
# The tools are in ../../../tools/gpkg-devel/
python3 ../../../tools/gpkg-devel/gpkg-build.py . -o ../../../export/x86_64/gemfetch/gemfetch_1.0.0_x86_64.gpkg

echo "--- Done! ---"
echo "Artifact: export/x86_64/gemfetch/gemfetch_1.0.0_x86_64.gpkg"
