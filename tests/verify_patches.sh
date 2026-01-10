#!/bin/bash

# Test script to verify that patches are correctly integrated and applied
# ALWAYS move test scripts to tests/ directory

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "=== GeminiOS Patch Verification Test ==="

# 1. Verify XOrg Server Patch
echo -n "[*] Testing xorg-server-1.20.14-glxdri2.patch: "
if grep -q "#undef bool" external_dependencies/xorg-server-1.20.14/glx/glxdri2.c; then
    echo -e "${GREEN}PASSED${NC} (Applied)"
else
    echo -e "${RED}FAILED${NC} (Not found in source)"
fi

# 2. Verify GObject-Introspection Patch
echo -n "[*] Testing gobject-introspection-1.78.1-msvc.patch: "
if grep -q "try:" external_dependencies/gobject-introspection-1.78.1/giscanner/ccompiler.py; then
    echo -e "${GREEN}PASSED${NC} (Applied)"
else
    echo -e "${RED}FAILED${NC} (Not found in source)"
fi

# 3. Verify GLib Patch
echo -n "[*] Testing glib-2.78.3-utils.patch: "
if ! grep -q "distutils.version.LooseVersion" external_dependencies/glib-2.78.3/gio/gdbus-2.0/codegen/utils.py; then
    echo -e "${GREEN}PASSED${NC} (Applied)"
else
    echo -e "${RED}FAILED${NC} (Found distutils.version.LooseVersion)"
fi

# 4. Verify LibFFI Patch
echo -n "[*] Testing libffi-3.4.4.patch: "
if grep -q "open_temp_exec_file" external_dependencies/libffi-3.4.4/src/tramp.c; then
    echo -e "${GREEN}PASSED${NC} (Applied)"
else
    echo -e "${RED}FAILED${NC} (Not found in source)"
fi

# 5. Verify GLibc srcdir fix (Running a dry-run of the sed command)
echo -n "[*] Testing GLibc Makefile sed fix: "
# Create a dummy Makefile to test the sed command
echo "srcdir = ../something" > /tmp/test_glibc_makefile
DEP_DIR="/abs/path/to/deps"
GLIBC_VER="2.39"
sed "s|^srcdir = .*|srcdir = $DEP_DIR/glibc-$GLIBC_VER|" /tmp/test_glibc_makefile > /tmp/test_glibc_makefile_fixed
if grep -q "srcdir = /abs/path/to/deps/glibc-2.39" /tmp/test_glibc_makefile_fixed; then
    echo -e "${GREEN}PASSED${NC} (Sed logic works)"
else
    echo -e "${RED}FAILED${NC} (Sed logic failed)"
fi
rm /tmp/test_glibc_makefile /tmp/test_glibc_makefile_fixed

# 6. Verify Build Script Logic
echo "=== Verifying Build Script Logic ==="

check_script_patch() {
    local script=$1
    local patch_file=$2
    echo -n "[*] Checking $script for $patch_file: "
    if grep -q "patch.*$patch_file" "$script"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}MISSING${NC}"
        exit_code=1
    fi
}

exit_code=0
check_script_patch "ports/xorg-server/build.sh" "xorg-server-1.20.14-glxdri2.patch"
check_script_patch "ports/gobject-introspection/build.sh" "gobject-introspection-1.78.1-msvc.patch"
check_script_patch "ports/glib/build.sh" "glib-2.78.3-utils.patch"
check_script_patch "ports/libffi/build.sh" "libffi-3.4.4.patch"
check_script_patch "ports/libxrender/build.sh" "libXrender-0.9.11-glyph.patch"

if [ $exit_code -eq 0 ]; then
    echo "=== All build scripts correctly configured! ==="
else
    echo "=== Some build scripts are missing patch logic! ==="
    exit 1
fi
