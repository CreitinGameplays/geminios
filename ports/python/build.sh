#!/bin/bash
set -e

# Derived from deprecated/build_old.sh

PYTHON_VER="3.11.9"

# 1. Download and Extract
download_and_extract "https://www.python.org/ftp/python/$PYTHON_VER/Python-$PYTHON_VER.tar.xz" "Python-$PYTHON_VER.tar.xz" "Python-$PYTHON_VER"

cd "$DEP_DIR/Python-$PYTHON_VER"

# 2. Cleanup
echo "Cleaning stale Python build artifacts..."
rm -f Modules/Setup.local
rm -f "$ROOTFS/usr/lib64/libpython*"
make distclean || true

# 3. Configure

# Unset flags that might pollute the build-tool (host) compilation
unset CFLAGS CXXFLAGS LDFLAGS

# We use --with-build-python to use the host's python for freezing modules
# We use --host=x86_64-gemini-linux-gnu to trigger cross-compilation mode
# The shim wrapper will automatically handle --sysroot
./configure --prefix=/usr --enable-shared --without-ensurepip --disable-test-modules \
    --with-openssl="$ROOTFS/usr" \
    --build=x86_64-linux-gnu \
    --host=x86_64-gemini-linux-gnu \
    ac_cv_file__dev_ptmx=yes ac_cv_file__dev_ptc=no \
    PLATLIBDIR=lib64 \
    --disable-ipv6 \
    --with-build-python=$HOME/.pyenv/versions/3.11.9/bin/python3.11

# 4. Build
make -j$JOBS

# 5. Fix sysconfigdata
SYSCONFIG_FILE=$(find build/lib* -name "_sysconfigdata*.py" 2>/dev/null | head -n 1)
if [ -n "$SYSCONFIG_FILE" ]; then
    echo "Applying sysconfigdata fix..."
    cp -v "$SYSCONFIG_FILE" build/ || true
    cp -v "$SYSCONFIG_FILE" . || true
fi

# 6. Install
make install DESTDIR="$ROOTFS"

# 7. Symlinks
ln -sf python3.11 "$ROOTFS/usr/bin/python3"
ln -sf python3 "$ROOTFS/usr/bin/python"