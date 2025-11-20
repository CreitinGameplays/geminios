#!/bin/bash
set -e

echo "--- Building GemFetch ---"

# 1. Compile static binary
# We optimize for size (-Os) and strip symbols
g++ -static -Os -o gemfetch gemfetch.cpp
strip gemfetch

# 2. Add GPKG Magic Header
# This is required for the package manager to verify the file
echo "Creating gemfetch.gpkg..."
( printf "GPKG"; cat gemfetch ) > gemfetch.gpkg

echo "--- Done! ---"
echo "Artifact: packages/gemfetch/gemfetch.gpkg"
echo "Upload this file to: https://cdn.rx580iloveyou.qzz.io/geminios/gemfetch.gpkg"
