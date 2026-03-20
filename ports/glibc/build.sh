#!/bin/bash
set -e

GLIBC_VER="2.39"
download_and_extract "https://ftp.gnu.org/gnu/glibc/glibc-$GLIBC_VER.tar.xz" "glibc-$GLIBC_VER.tar.xz" "glibc-$GLIBC_VER"

mkdir -p build
cd build

# Configure for x86_64 linux
if [ ! -f "Makefile" ]; then
    PYTHON_PROG=/usr/bin/python3 "$DEP_DIR/glibc-$GLIBC_VER/configure" --prefix=/usr --enable-kernel=4.14 --disable-werror \
        --disable-profile --without-gd --without-selinux
    
    # Fix srcdir in Makefile to be absolute if it's not
    sed -i "s|^srcdir = .*|srcdir = $DEP_DIR/glibc-$GLIBC_VER|" Makefile
fi

make -j$JOBS

# Glibc does not delete stale headers under bits/, so a reused rootfs can end
# up with a mixed header set from different glibc releases. Reset the glibc-
# managed bits trees before install to keep the headers self-consistent.
echo "Resetting glibc bits headers..."
rm -rf "$ROOTFS/usr/include/bits" "$ROOTFS/usr/include/x86_64-linux-gnu/bits"
mkdir -p "$ROOTFS/usr/include" "$ROOTFS/usr/include/x86_64-linux-gnu"

# Install to rootfs
make install DESTDIR="$ROOTFS"

# Sanity-check the staged pthread headers. This catches mixed installs early
# instead of surfacing later as opaque C++ std::mutex build errors.
THREAD_BITS_HEADER="$ROOTFS/usr/include/x86_64-linux-gnu/bits/thread-shared-types.h"
PTHREAD_HEADER="$ROOTFS/usr/include/pthread.h"
EXPECTED_COND_INIT_OLD='#define PTHREAD_COND_INITIALIZER { { {0}, {0}, {0, 0}, {0, 0}, 0, 0, {0, 0} } }'
EXPECTED_COND_INIT_NEW='#define PTHREAD_COND_INITIALIZER { { {0}, {0}, {0, 0}, 0, 0, {0, 0}, 0, 0 } }'

if [ -f "$THREAD_BITS_HEADER" ] && [ -f "$PTHREAD_HEADER" ]; then
    actual_cond_init="$(grep '^#define PTHREAD_COND_INITIALIZER ' "$PTHREAD_HEADER" || true)"
    if grep -q "__unused_initialized_1" "$THREAD_BITS_HEADER"; then
        expected_cond_init="$EXPECTED_COND_INIT_NEW"
    else
        expected_cond_init="$EXPECTED_COND_INIT_OLD"
    fi

    if [ "$actual_cond_init" != "$expected_cond_init" ]; then
        echo "Normalizing pthread condition initializer to match installed bits headers..."
        sed -i "s|^#define PTHREAD_COND_INITIALIZER .*|$expected_cond_init|" "$PTHREAD_HEADER"
    fi
fi

# 2. Ensure critical static libraries are in the expected location
cp -v libc_nonshared.a "$ROOTFS/usr/lib64/" || true
cp -v libc.a "$ROOTFS/usr/lib64/" || true
cp -v math/libm.a "$ROOTFS/usr/lib64/" || true

# Fixup linker scripts
echo "Ensuring glibc linker scripts are correct..."
if [ -f "$ROOTFS/usr/lib64/libc.so" ]; then
    cat > "$ROOTFS/usr/lib64/libc.so" <<EOF
/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( libc.so.6 libc_nonshared.a AS_NEEDED ( ld-linux-x86-64.so.2 ) )
EOF
fi
if [ -f "$ROOTFS/usr/lib64/libm.so" ]; then
    cat > "$ROOTFS/usr/lib64/libm.so" <<EOF
/* GNU ld script */
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( libm.so.6 AS_NEEDED ( libmvec.so.1 ) )
EOF
fi

# Locale generation
echo "Generating locales..."
mkdir -p "$ROOTFS/usr/lib/locale"
rm -rf "$ROOTFS/usr/lib/locale/"* # Clean old locales

GLIBC_SRC="$DEP_DIR/glibc-$GLIBC_VER"

if [ -x "locale/localedef" ]; then
     echo "Using local localedef to generate locale-archive..."
     # We generate individual directories to work with LOCPATH
     ./elf/ld.so --library-path . \
        ./locale/localedef \
        --no-archive \
        --prefix="$ROOTFS" \
        -i "$GLIBC_SRC/localedata/locales/en_US" \
        -f "$GLIBC_SRC/localedata/charmaps/UTF-8" \
        en_US.UTF-8 || echo "WARNING: Localedef failed for en_US.UTF-8!"

     ./elf/ld.so --library-path . \
        ./locale/localedef \
        --no-archive \
        --prefix="$ROOTFS" \
        -i "$GLIBC_SRC/localedata/locales/C" \
        -f "$GLIBC_SRC/localedata/charmaps/UTF-8" \
        C.UTF-8 || echo "WARNING: Localedef failed for C.UTF-8!"

     # localedef might normalize UTF-8 to utf8. Let's ensure the manifest names exist.
     cd "$ROOTFS/usr/lib/locale"
     if [ -d "en_US.utf8" ] && [ ! -d "en_US.UTF-8" ]; then
         mv en_US.utf8 en_US.UTF-8
     fi
     if [ -d "C.utf8" ] && [ ! -d "C.UTF-8" ]; then
         mv C.utf8 C.UTF-8
     fi

     # Create symlinks for common variants
     ln -sf en_US.UTF-8 en_US.utf8
     ln -sf en_US.UTF-8 en_US
     ln -sf C.UTF-8 C.utf8
     ln -sf C.UTF-8 C
     cd -
fi

# iconv configuration cache
if [ -x "iconv/iconvconfig" ]; then
    echo "Generating gconv-modules.cache..."
    ./elf/ld.so --library-path . ./iconv/iconvconfig \
        --prefix="$ROOTFS" || echo "WARNING: iconvconfig failed!"
fi
