#!/bin/bash
set -e # Exit immediately if a command fails
set -o pipefail # Exit if any command in a pipe fails

# Configuration
ENABLE_DEBUG=false # Set to true to enable detailed debug logs
DEP_DIR="external_dependencies"
mkdir -p "$DEP_DIR"

KERNEL_VERSION="linux-6.6.14" # Change this if you update kernel version
KERNEL_BZIMAGE="$DEP_DIR/$KERNEL_VERSION/arch/x86/boot/bzImage"
JOBS=${JOBS:-$(nproc)} # Number of parallel jobs, default to CPU count. Lower if RAM is tight.
echo "Using $JOBS parallel jobs."

# Helper to download and extract dependencies
# Usage: download_and_extract <url> <archive_name> <extracted_dir_name>
download_and_extract() {
    local url="$1"
    local archive="$2"
    local dirname="$3"

    if [ ! -d "$DEP_DIR/$dirname" ]; then
        echo "Downloading and Extracting $dirname..."
        if [ ! -f "$DEP_DIR/$archive" ]; then
            wget -O "$DEP_DIR/$archive" "$url"
        fi
        tar -xf "$DEP_DIR/$archive" -C "$DEP_DIR"
        rm "$DEP_DIR/$archive"
    fi
}

echo "--- 0. Preparing Rootfs ---"
# Clean old artifacts and create directory hierarchy FIRST
# DO NOT DELETE ROOTFS! It contains static source files (like /usr/lib/grub).
# We only clean compiled binaries to ensure they are updated.
rm -rf rootfs/bin
rm -f isodir/boot/initramfs.cpio.*
mkdir -p isodir/boot
mkdir -p isodir/boot/grub
mkdir -p rootfs/bin
mkdir -p rootfs/boot
mkdir -p rootfs/proc
mkdir -p rootfs/sys
mkdir -p rootfs/dev
mkdir -p rootfs/etc
mkdir -p rootfs/tmp
mkdir -p rootfs/mnt
mkdir -p rootfs/var/repo
mkdir -p rootfs/bin/apps
mkdir -p rootfs/bin/apps/system
mkdir -p rootfs/usr/bin
mkdir -p rootfs/usr/share
mkdir -p rootfs/usr/local
mkdir -p rootfs/var/log
mkdir -p rootfs/var/tmp
mkdir -p rootfs/run
mkdir -p rootfs/sbin
mkdir -p rootfs/lib64
mkdir -p rootfs/usr/lib64

# Standardize library paths to avoid "Split Libs" issues and save space
# /lib -> lib64 and /usr/lib -> lib64
if [ ! -L "rootfs/lib" ]; then
    echo "Converting /lib to symlink..."
    if [ -d "rootfs/lib" ]; then
        cp -an rootfs/lib/* rootfs/lib64/ 2>/dev/null || true
        rm -rf rootfs/lib
    fi
    ln -sf lib64 rootfs/lib
fi
if [ ! -L "rootfs/usr/lib" ]; then
    echo "Converting /usr/lib to symlink..."
    if [ -d "rootfs/usr/lib" ]; then
        cp -an rootfs/usr/lib/* rootfs/usr/lib64/ 2>/dev/null || true
        rm -rf rootfs/usr/lib
    fi
    ln -sf lib64 rootfs/usr/lib
fi

# Safety fix for existing .la files in case of dirty state
if [ -d "rootfs/usr/lib64" ]; then
    echo "Ensuring .la files point to target paths..."
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find rootfs -name "*.la" -delete
fi

echo "--- 1. Compiling Userspace ---"
# -static is CRITICAL. We have no shared libraries (.so) in the OS.
# We must bundle all C++ logic inside the binary.
# We link OpenSSL (-lssl -lcrypto) for HTTPS support.
if [ ! -f "src/network.cpp" ]; then
    echo "ERROR: src/network.cpp is missing!"
    exit 1
fi

CXXFLAGS="-static -O2"
if [ "$ENABLE_DEBUG" = "true" ]; then
    CXXFLAGS="$CXXFLAGS -DDEBUG_MODE"
fi

echo "Compiling Shared Signals..."
g++ -c src/signals.cpp -o src/signals.o

echo "Compiling User Management..."
g++ -c src/user_mgmt.cpp -o src/user_mgmt.o -lssl -lcrypto

echo "Compiling Init (Shell)..."
g++ $CXXFLAGS -o init src/init.cpp src/network.cpp src/signals.o src/user_mgmt.o -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip init

# Install init immediately
cp init rootfs/init
chmod +x rootfs/init
# Also install to /bin/init so the installer can find it and 'su' works
cp init rootfs/bin/init

echo "--- 1.1 compiling Packages ---"

# Helper to compile simple system packages
compile_sys_pkg() {
    PKG=$1
    echo "Compiling system package: $PKG"
    g++ -static -O2 -I src -o rootfs/bin/apps/system/$PKG packages/system/$PKG/$PKG.cpp
    strip rootfs/bin/apps/system/$PKG
}

# Compile simple commands
for pkg in ls pwd cat mkdir touch uname free reboot poweroff clear help gtop rm df mount dd fdisk mkfs lsblk copy move chmod echo kill ps head tail wc whoami env date keymap loadkmap uptime export; do
	compile_sys_pkg $pkg &
    # If we hit the job limit, wait for background tasks to finish
    if [[ $(jobs -r -p | wc -l) -ge $JOBS ]]; then
        wait -n
    fi
done
wait

# Compile Complex Packages (requiring network)
echo "Compiling gpkg..."
g++ $CXXFLAGS -I src -o rootfs/bin/apps/system/gpkg packages/system/gpkg/gpkg.cpp src/network.cpp src/signals.o -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip rootfs/bin/apps/system/gpkg

echo "Compiling ping..."
g++ $CXXFLAGS -I src -o rootfs/bin/apps/system/ping packages/system/ping/ping.cpp src/network.cpp src/signals.o -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip rootfs/bin/apps/system/ping

echo "Compiling greq..."
g++ $CXXFLAGS -I src -o rootfs/bin/apps/system/greq packages/system/greq/greq.cpp src/network.cpp src/signals.o -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip rootfs/bin/apps/system/greq

echo "Compiling tar (with gzip support)..."
g++ $CXXFLAGS -I src -o rootfs/bin/apps/system/tar packages/system/tar/tar.cpp src/signals.o -lz -lpthread
strip rootfs/bin/apps/system/tar

echo "Compiling gzip..."
g++ $CXXFLAGS -I src -o rootfs/bin/apps/system/gzip packages/system/gzip/gzip.cpp src/signals.o -lz -lpthread
strip rootfs/bin/apps/system/gzip

echo "Compiling User Tools (passwd, adduser...)"
for tool in passwd adduser userdel usermod su sudo chown; do
    echo "  - $tool"
    g++ $CXXFLAGS -I src -o rootfs/bin/apps/system/$tool packages/system/$tool/$tool.cpp src/user_mgmt.o -lssl -lcrypto -lz -lzstd -ldl -lpthread
    strip rootfs/bin/apps/system/$tool
done

echo "Compiling Installer..."
g++ $CXXFLAGS -I src -o rootfs/bin/apps/system/installer packages/system/installer/installer.cpp src/user_mgmt.o -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip rootfs/bin/apps/system/installer

echo "--- 1.4 Compiling Base System (Glibc & Foundation) ---"

# 0. KERNEL HEADERS (Required for Glibc and other system tools)
if [ ! -d "rootfs/usr/include/linux" ]; then
    echo "Installing Kernel Headers..."
    if [ -d "$DEP_DIR/$KERNEL_VERSION" ]; then
        mkdir -p rootfs/usr/include
        pushd "$DEP_DIR/$KERNEL_VERSION"
        # We use an absolute path for INSTALL_HDR_PATH to avoid issues with pushd
        make headers_install ARCH=x86_64 INSTALL_HDR_PATH="$(pwd)/../../rootfs/usr"
        popd
    else
        echo "ERROR: Kernel source not found at $DEP_DIR/$KERNEL_VERSION"
        echo "Please ensure the kernel source is extracted in the external_dependencies directory."
        exit 1
    fi
fi

# 1. GLIBC (Dynamic Loader & Standard Library)
GLIBC_VER="2.39"
if [ ! -f "rootfs/lib64/libc.so.6" ] || [ ! -f "rootfs/usr/include/stdio.h" ]; then
    echo "Downloading and Building Glibc $GLIBC_VER..."
    download_and_extract "https://ftp.gnu.org/gnu/glibc/glibc-$GLIBC_VER.tar.xz" "glibc-$GLIBC_VER.tar.xz" "glibc-$GLIBC_VER"
    
    mkdir -p glibc-build
    pushd glibc-build
    # Configure for x86_64 linux
    ../$DEP_DIR/glibc-$GLIBC_VER/configure --prefix=/usr --enable-kernel=4.14 --disable-werror \
        --disable-profile --without-gd --without-selinux
    
    make -j$JOBS
    # Install to rootfs
    make install DESTDIR=$(pwd)/../rootfs
    
    # 2. Ensure critical static libraries are in the expected location
    # Some build systems (like libtool) expect these in usr/lib64
    echo "Copying missing static libraries to rootfs..."
    cp -v libc_nonshared.a ../rootfs/usr/lib64/ || true
    cp -v libc.a ../rootfs/usr/lib64/ || true
    cp -v math/libm.a ../rootfs/usr/lib64/ || true
    
    popd
fi

# --- POST-INSTALL FIXUP (Critical for cross-compilation/linking) ---
# Ensure glibc linker scripts use absolute paths that work with --sysroot.
# We use absolute paths because 'ld --sysroot' correctly prepends the sysroot to them.
echo "Ensuring glibc linker scripts are correct..."
if [ -f "rootfs/usr/lib64/libc.so" ]; then
    cat > rootfs/usr/lib64/libc.so <<EOF
/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( /lib64/libc.so.6 /usr/lib64/libc_nonshared.a AS_NEEDED ( /lib64/ld-linux-x86-64.so.2 ) )
EOF
fi
if [ -f "rootfs/usr/lib64/libm.so" ]; then
    cat > rootfs/usr/lib64/libm.so <<EOF
/* GNU ld script */
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( /lib64/libm.so.6 AS_NEEDED ( /lib64/libmvec.so.1 ) )
EOF
fi

# --- FIX: Enforce sysroot globally after Glibc ---
# This ensures all subsequent libraries and tools are linked against the Target (rootfs)
# and NOT the Host. This prevents "stack smashing" and ABI mismatch.
# Added -Wno-error to satisfy user request to disable treating warnings as errors.
export CFLAGS="--sysroot=$(pwd)/rootfs -O2 -fPIC -Wno-error"
export CXXFLAGS="--sysroot=$(pwd)/rootfs -O2 -fPIC -Wno-error"
export LDFLAGS="--sysroot=$(pwd)/rootfs"
# -------------------------------------------------
    
    # 1.4.1 Generate Locales (fixes Perl warnings)
    # We generate individual files (--no-archive) to work with LOCPATH
    if [ ! -d "rootfs/usr/lib/locale/en_US.UTF-8" ]; then
        echo "Generating en_US.UTF-8 locale..."
        mkdir -p rootfs/usr/lib/locale
        # Remove archive if it exists to avoid confusion
        rm -f rootfs/usr/lib/locale/locale-archive
        
        GLIBC_SRC="$DEP_DIR/glibc-2.39"
        GLIBC_BUILD="glibc-build"
        
        if [ -x "$GLIBC_BUILD/locale/localedef" ]; then
             echo "Using glibc-build localedef..."
             $GLIBC_BUILD/elf/ld.so --library-path $GLIBC_BUILD \
                $GLIBC_BUILD/locale/localedef \
                --no-archive \
                --prefix=$(pwd)/rootfs \
                -i $GLIBC_SRC/localedata/locales/en_US \
                -f $GLIBC_SRC/localedata/charmaps/UTF-8 \
                en_US.UTF-8 || echo "WARNING: Localedef failed!"
            
            # Create symlink for case-insensitivity (localedef often normalizes to .utf8)
            if [ -d "rootfs/usr/lib/locale/en_US.utf8" ] && [ ! -d "rootfs/usr/lib/locale/en_US.UTF-8" ]; then
                ln -sf en_US.utf8 rootfs/usr/lib/locale/en_US.UTF-8
            fi
            if [ -d "rootfs/usr/lib/locale/C.utf8" ] && [ ! -d "rootfs/usr/lib/locale/C.UTF-8" ]; then
                ln -sf C.utf8 rootfs/usr/lib/locale/C.UTF-8
            fi
        else
            echo "WARNING: localedef from glibc-build not found. Using host localedef (might fail/mismatch)."
            if command -v localedef >/dev/null 2>&1; then
                localedef --no-archive --prefix=$(pwd)/rootfs -i en_US -f UTF-8 en_US.UTF-8 || true
                if [ -d "rootfs/usr/lib/locale/en_US.utf8" ] && [ ! -d "rootfs/usr/lib/locale/en_US.UTF-8" ]; then
                    ln -sf en_US.utf8 rootfs/usr/lib/locale/en_US.UTF-8
                fi
                 if [ -d "rootfs/usr/lib/locale/C.utf8" ] && [ ! -d "rootfs/usr/lib/locale/C.UTF-8" ]; then
                    ln -sf C.utf8 rootfs/usr/lib/locale/C.UTF-8
                fi
            fi
        fi
    fi

    # 1.4.1 iconv configuration cache (Critical for charset conversion)
    if [ -x "glibc-build/iconv/iconvconfig" ] && [ ! -f "rootfs/usr/lib/gconv/gconv-modules.cache" ]; then
        echo "Generating gconv-modules.cache..."
        ./glibc-build/elf/ld.so --library-path ./glibc-build ./glibc-build/iconv/iconvconfig \
            --prefix=$(pwd)/rootfs || echo "WARNING: iconvconfig failed!"
    fi


# 1.5. LIBXCRYPT (Replacement for old glibc libcrypt, required by Perl)
LIBXCRYPT_VER="4.4.36"
if [ ! -f "rootfs/lib64/libcrypt.so.1" ]; then
    echo "Downloading and Building libxcrypt $LIBXCRYPT_VER..."
    download_and_extract "https://github.com/besser82/libxcrypt/releases/download/v$LIBXCRYPT_VER/libxcrypt-$LIBXCRYPT_VER.tar.xz" "libxcrypt-$LIBXCRYPT_VER.tar.xz" "libxcrypt-$LIBXCRYPT_VER"
    
    pushd "$DEP_DIR/libxcrypt-$LIBXCRYPT_VER"
    # We enable obsolete API to provide libcrypt.so.1 for compatibility
    ./configure --prefix=/usr \
                --enable-static \
                --enable-hashes=all \
                --enable-obsolete-api=glibc \
                --disable-werror
    
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
    
    # Ensure libcrypt.so.1 is in lib64 if it ended up in lib
    if [ -f "rootfs/usr/lib/libcrypt.so.1" ] && [ ! -f "rootfs/lib64/libcrypt.so.1" ]; then
        cp -d rootfs/usr/lib/libcrypt.so.1* rootfs/lib64/
    fi
fi

echo "--- PHASE 1: Build Tools & Compilers ---"

# 1. PYTHON 3 (Required for Meson/Ninja/XCB)
PYTHON_VER="3.11.9"
if [ ! -f "rootfs/usr/bin/python3" ]; then
    echo "Downloading and Building Python $PYTHON_VER..."
    download_and_extract "https://www.python.org/ftp/python/$PYTHON_VER/Python-$PYTHON_VER.tar.xz" "Python-$PYTHON_VER.tar.xz" "Python-$PYTHON_VER"

    pushd "$DEP_DIR/Python-$PYTHON_VER"

    # CLEANUP: Remove stale static configuration and libraries from previous builds
    echo "Cleaning stale Python build artifacts..."
    rm -f Modules/Setup.local
    rm -f ../../rootfs/usr/lib64/libpython*
    make distclean || true

    # Configure for shared (dynamic) build
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"

    ./configure --prefix=/usr --enable-shared --without-ensurepip --disable-test-modules \
        --with-openssl=$(pwd)/../../rootfs/usr \
        --build=x86_64-linux-gnu --host=x86_64-linux-gnu \
        ac_cv_file__dev_ptmx=yes ac_cv_file__dev_ptc=no \
        PLATLIBDIR=lib64 \
        LDFLAGS="-L/usr/lib64 -Wl,-rpath=/usr/lib64" \
        CPPFLAGS="-I$(pwd)/../../rootfs/usr/include"
    
    make -j$JOBS
    
    # Fix for installation failure
    SYSCONFIG_FILE=$(find build/lib* -name "_sysconfigdata*.py" 2>/dev/null | head -n 1)
    if [ -n "$SYSCONFIG_FILE" ]; then
        cp -v "$SYSCONFIG_FILE" build/
        cp -v "$SYSCONFIG_FILE" .
    fi

    make install DESTDIR=$(pwd)/../../rootfs
    popd
    
    # Fix python symlinks
    ln -sf python3.11 rootfs/usr/bin/python3
    ln -sf python3 rootfs/usr/bin/python
fi

# 2. PKG-CONFIG (Library Helper)
PKG_CONFIG_VER="0.29.2"
if [ ! -f "rootfs/usr/bin/pkg-config" ]; then
    echo "Downloading and Building Pkg-config $PKG_CONFIG_VER..."
    download_and_extract "https://pkg-config.freedesktop.org/releases/pkg-config-$PKG_CONFIG_VER.tar.gz" "pkg-config-$PKG_CONFIG_VER.tar.gz" "pkg-config-$PKG_CONFIG_VER"
    
    pushd "$DEP_DIR/pkg-config-$PKG_CONFIG_VER"
    ./configure --prefix=/usr --with-internal-glib --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 3. BISON (Parser Generator)
BISON_VER="3.8.2"
if [ ! -f "rootfs/usr/bin/bison" ]; then
    echo "Downloading and Building Bison $BISON_VER..."
    download_and_extract "https://ftp.gnu.org/gnu/bison/bison-$BISON_VER.tar.xz" "bison-$BISON_VER.tar.xz" "bison-$BISON_VER"

    pushd "$DEP_DIR/bison-$BISON_VER"
    ./configure --prefix=/usr --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

# 4. FLEX (Lexical Analyzer)
FLEX_VER="2.6.4"
if [ ! -f "rootfs/usr/bin/flex" ]; then
    echo "Downloading and Building Flex $FLEX_VER..."
    download_and_extract "https://github.com/westes/flex/releases/download/v$FLEX_VER/flex-$FLEX_VER.tar.gz" "flex-$FLEX_VER.tar.gz" "flex-$FLEX_VER"

    pushd "$DEP_DIR/flex-$FLEX_VER"
    ./configure --prefix=/usr --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
    ln -sf flex rootfs/usr/bin/lex
fi

# 5. GPERF (Perfect Hash Function Generator)
GPERF_VER="3.1"
if [ ! -f "rootfs/usr/bin/gperf" ]; then
    echo "Downloading and Building Gperf $GPERF_VER..."
    download_and_extract "https://ftp.gnu.org/pub/gnu/gperf/gperf-$GPERF_VER.tar.gz" "gperf-$GPERF_VER.tar.gz" "gperf-$GPERF_VER"

    pushd "$DEP_DIR/gperf-$GPERF_VER"
    ./configure --prefix=/usr --docdir=/usr/share/doc/gperf-$GPERF_VER --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 6. GETTEXT (Internationalization tools)
GETTEXT_VER="0.22.4"
if [ ! -f "rootfs/usr/bin/msgfmt" ]; then
    echo "Downloading and Building Gettext $GETTEXT_VER..."
    download_and_extract "https://ftp.gnu.org/gnu/gettext/gettext-$GETTEXT_VER.tar.xz" "gettext-$GETTEXT_VER.tar.xz" "gettext-$GETTEXT_VER"

    pushd "$DEP_DIR/gettext-$GETTEXT_VER"
    ./configure --prefix=/usr --disable-static --enable-shared --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

# 7. PERL (Required for Xorg builds)
PERL_VER="5.38.2"
if [ ! -f "rootfs/usr/bin/perl" ]; then
    echo "Downloading and Building Perl $PERL_VER..."
    download_and_extract "https://www.cpan.org/src/5.0/perl-$PERL_VER.tar.gz" "perl-$PERL_VER.tar.gz" "perl-$PERL_VER"
    
    pushd "$DEP_DIR/perl-$PERL_VER"
    ./Configure -des -Dprefix=/usr -Duseshrplib
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd

    if [ -f "rootfs/usr/lib/perl5/$PERL_VER/x86_64-linux/CORE/libperl.so" ]; then
        cp -v rootfs/usr/lib/perl5/$PERL_VER/x86_64-linux/CORE/libperl.so rootfs/usr/lib/
    fi
fi

# 8. UTIL-MACROS (Required for X11 build system)
UTIL_MACROS_VER="1.20.0"
if [ ! -f "rootfs/usr/share/pkgconfig/xorg-macros.pc" ]; then
    echo "Building util-macros $UTIL_MACROS_VER..."
    download_and_extract "https://www.x.org/archive/individual/util/util-macros-$UTIL_MACROS_VER.tar.gz" "util-macros-$UTIL_MACROS_VER.tar.gz" "util-macros-$UTIL_MACROS_VER"

    pushd "$DEP_DIR/util-macros-$UTIL_MACROS_VER"
    ./configure --prefix=/usr --host=x86_64-linux-gnu
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

echo "--- PHASE 2: Low-Level System Dependencies ---"

# 1. ZLIB (Compression library)
ZLIB_VER="1.3.1"
if [ ! -f "rootfs/usr/lib64/libz.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/zlib.pc" ]; then
    echo "Downloading and Building Zlib $ZLIB_VER..."
    download_and_extract "https://zlib.net/zlib-$ZLIB_VER.tar.gz" "zlib-$ZLIB_VER.tar.gz" "zlib-$ZLIB_VER"

    pushd "$DEP_DIR/zlib-$ZLIB_VER"
    # Ensure we use the target compiler and sysroot during configure
    # This prevents the "missing snprintf" warning and ensures correct header detection.
    CC="gcc --sysroot=$(pwd)/../../rootfs" ./configure --prefix=/usr --libdir=/usr/lib64
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

# 2. OPENSSL (Cryptography)
OPENSSL_VER="3.3.0"
if [ ! -f "rootfs/usr/lib64/libssl.so.3" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/openssl.pc" ]; then
    echo "Downloading and Building OpenSSL $OPENSSL_VER..."
    download_and_extract "https://www.openssl.org/source/openssl-$OPENSSL_VER.tar.gz" "openssl-$OPENSSL_VER.tar.gz" "openssl-$OPENSSL_VER"
    
   pushd "$DEP_DIR/openssl-$OPENSSL_VER"
    ./config --prefix=/usr --libdir=lib64 --openssldir=/etc/ssl shared zlib-dynamic
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

# 2.5. ZSTD (Compression library, required by Mesa)
ZSTD_VER="1.5.5"
if [ ! -f "rootfs/usr/lib64/libzstd.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/libzstd.pc" ]; then
    echo "Downloading and Building Zstd $ZSTD_VER..."
    download_and_extract "https://github.com/facebook/zstd/releases/download/v$ZSTD_VER/zstd-$ZSTD_VER.tar.gz" "zstd-$ZSTD_VER.tar.gz" "zstd-$ZSTD_VER"
    
    pushd "$DEP_DIR/zstd-$ZSTD_VER"
    make -j$JOBS PREFIX=/usr LIBDIR=/usr/lib64
    make install DESTDIR=$(pwd)/../../rootfs PREFIX=/usr LIBDIR=/usr/lib64
    popd
fi

# 2.6. LIBELF (Required by Mesa)
# We use elfutils to provide libelf.
ELFUTILS_VER="0.191"
if [ ! -f "rootfs/usr/lib64/libelf.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/libelf.pc" ]; then
    echo "Downloading and Building elfutils $ELFUTILS_VER..."
    download_and_extract "https://sourceware.org/elfutils/ftp/$ELFUTILS_VER/elfutils-$ELFUTILS_VER.tar.bz2" "elfutils-$ELFUTILS_VER.tar.bz2" "elfutils-$ELFUTILS_VER"
    
    pushd "$DEP_DIR/elfutils-$ELFUTILS_VER"
    # Elfutils is picky. We only want libelf for now.
    ./configure --prefix=/usr --libdir=/usr/lib64 \
                --disable-debuginfod --disable-libdebuginfod \
                --disable-nls --disable-werror \
                --host=x86_64-linux-gnu
    
    # Build only libelf and dependencies
    make -C lib -j$JOBS
    make -C libelf -j$JOBS
    
    # Install libelf
    make -C libelf install DESTDIR=$(pwd)/../../rootfs
    
    # Manually install the pkg-config file if the above didn't catch it
    mkdir -p ../../rootfs/usr/lib64/pkgconfig
    if [ -f "config/libelf.pc" ]; then
        cp config/libelf.pc ../../rootfs/usr/lib64/pkgconfig/
    elif [ -f "libelf/libelf.pc" ]; then
        cp libelf/libelf.pc ../../rootfs/usr/lib64/pkgconfig/
    fi
    popd
fi

# 3. LIBXML2 (XML Parser)
LIBXML2_VER="2.12.4"
if [ ! -f "rootfs/usr/lib64/libxml2.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/libxml-2.0.pc" ]; then
    echo "Downloading and Building libxml2 $LIBXML2_VER..."
    download_and_extract "https://download.gnome.org/sources/libxml2/2.12/libxml2-$LIBXML2_VER.tar.xz" "libxml2-$LIBXML2_VER.tar.xz" "libxml2-$LIBXML2_VER"

    pushd "$DEP_DIR/libxml2-$LIBXML2_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    ./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc \
        --disable-static --without-python --without-icu --with-zlib --host=x86_64-linux-gnu
    
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 4. EXPAT (XML Parser)
EXPAT_VER="2.6.0"
if [ ! -f "rootfs/usr/lib64/libexpat.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/expat.pc" ]; then
    echo "Building expat $EXPAT_VER (using CMake)..."
    download_and_extract "https://github.com/libexpat/libexpat/releases/download/R_2_6_0/expat-$EXPAT_VER.tar.xz" "expat-$EXPAT_VER.tar.xz" "expat-$EXPAT_VER"
    
    pushd "$DEP_DIR/expat-$EXPAT_VER"
    rm -rf build_cmake
    mkdir -p build_cmake && cd build_cmake
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_INSTALL_LIBDIR=lib64 \
          -DBUILD_SHARED_LIBS=ON \
          -DEXPAT_BUILD_EXAMPLES=OFF \
          -DEXPAT_BUILD_TESTS=OFF \
          -DEXPAT_BUILD_TOOLS=OFF \
          -DCMAKE_C_FLAGS="$CFLAGS" \
          -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
          ..
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../../rootfs
    popd
fi

# 5. UTIL-LINUX (libmount, libblkid)
UTIL_LINUX_VER="2.39.3"
if [ ! -f "rootfs/usr/lib64/libmount.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/mount.pc" ]; then
    echo "Downloading and Building util-linux $UTIL_LINUX_VER..."
    download_and_extract "https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/v2.39/util-linux-$UTIL_LINUX_VER.tar.xz" "util-linux-$UTIL_LINUX_VER.tar.xz" "util-linux-$UTIL_LINUX_VER"

    pushd "$DEP_DIR/util-linux-$UTIL_LINUX_VER"
    ./configure --prefix=/usr --libdir=/usr/lib64 \
        --disable-all-programs \
        --enable-libuuid \
        --enable-libblkid \
        --enable-libmount \
        --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

# 6. DBUS (Message Bus)
DBUS_VER="1.14.10"
if [ ! -f "rootfs/usr/bin/dbus-daemon" ]; then
    echo "Building dbus $DBUS_VER..."
    download_and_extract "https://dbus.freedesktop.org/releases/dbus/dbus-$DBUS_VER.tar.xz" "dbus-$DBUS_VER.tar.xz" "dbus-$DBUS_VER"
    
    pushd "$DEP_DIR/dbus-$DBUS_VER"
    ./configure --prefix=/usr \
                --libdir=/usr/lib64 \
                --sysconfdir=/etc \
                --localstatedir=/var \
                --disable-static \
                --disable-doxygen-docs \
                --disable-xml-docs \
                --with-console-auth-dir=/run/console/ \
                --with-dbus-user=messagebus \
                --with-system-pid-file=/run/dbus/pid \
                --with-system-socket=/run/dbus/system_bus_socket \
                --host=x86_64-linux-gnu
    
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs

    # FIX: Remove empty Libs.private from .pc file, which can confuse some pkg-config versions
    if [ -f "../../rootfs/usr/lib64/pkgconfig/dbus-1.pc" ]; then
        sed -i '/^Libs.private: *$/d' "../../rootfs/usr/lib64/pkgconfig/dbus-1.pc"
    fi

    popd
fi

# 7. LIBFFI (Foreign Function Interface)
LIBFFI_VER="3.4.4"
if [ ! -f "rootfs/usr/lib64/libffi.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/libffi.pc" ]; then
    echo "Building libffi $LIBFFI_VER..."
    download_and_extract "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VER/libffi-$LIBFFI_VER.tar.gz" "libffi-$LIBFFI_VER.tar.gz" "libffi-$LIBFFI_VER"
    
    pushd "$DEP_DIR/libffi-$LIBFFI_VER"
    ./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

# 8. PCRE2 (Required by GLib)
PCRE2_VER="10.42"
if [ ! -f "rootfs/usr/lib64/libpcre2-8.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/libpcre2-8.pc" ]; then
    echo "Building pcre2 $PCRE2_VER..."
    download_and_extract "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VER/pcre2-$PCRE2_VER.tar.bz2" "pcre2-$PCRE2_VER.tar.bz2" "pcre2-$PCRE2_VER"
    
    pushd "$DEP_DIR/pcre2-$PCRE2_VER"
    ./configure --prefix=/usr --libdir=/usr/lib64 --enable-unicode --enable-jit --disable-static --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

echo "--- PHASE 3: Core Object System (GLib) ---"

# 1. GLIB (Base library for GTK)
GLIB_VER="2.78.3"
if [ ! -f "rootfs/usr/lib64/libglib-2.0.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/glib-2.0.pc" ]; then
    echo "Building glib $GLIB_VER..."
    download_and_extract "https://download.gnome.org/sources/glib/2.78/glib-$GLIB_VER.tar.xz" "glib-$GLIB_VER.tar.xz" "glib-$GLIB_VER"
    
    pushd "$DEP_DIR/glib-$GLIB_VER"
    OLD_PYTHONHOME=$PYTHONHOME
    unset PYTHONHOME
    
    meson setup build --prefix=/usr --libdir=lib64 \
        -Ddefault_library=shared \
        -Dselinux=disabled \
        -Dlibmount=disabled \
        -Dtests=false \
        -Dwerror=false
        
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    
    export PYTHONHOME=$OLD_PYTHONHOME
    popd
fi

# 2. GOBJECT-INTROSPECTION (Middleware)
GIR_VER="1.78.1"
if [ ! -f "rootfs/usr/bin/g-ir-scanner" ]; then
    echo "Building gobject-introspection $GIR_VER..."
    download_and_extract "https://download.gnome.org/sources/gobject-introspection/1.78/gobject-introspection-$GIR_VER.tar.xz" "gobject-introspection-$GIR_VER.tar.xz" "gobject-introspection-$GIR_VER"
    
    pushd "$DEP_DIR/gobject-introspection-$GIR_VER"
    OLD_PYTHONHOME=$PYTHONHOME
    unset PYTHONHOME
    
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    # Point Meson to our built python and ensure it uses it for dependency lookups
    # We must provide LD_LIBRARY_PATH so the built python can find its shared libraries on the host.
    # We also add rootfs/usr/bin to PATH so that #!/usr/bin/env python3 in scripts finds our built python.
    OLD_LD_LIBRARY_PATH=$LD_LIBRARY_PATH
    OLD_PATH=$PATH
    export LD_LIBRARY_PATH="$(pwd)/../../rootfs/usr/lib64:$LD_LIBRARY_PATH"
    export PATH="$(pwd)/../../rootfs/usr/bin:$PATH"
    
    env -u LD_LIBRARY_PATH meson setup build --prefix=/usr --libdir=lib64 \
        -Dpython="$(pwd)/../../rootfs/usr/bin/python3" \
        -Ddoctool=disabled \
        -Dwerror=false
            
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
        
    export LD_LIBRARY_PATH=$OLD_LD_LIBRARY_PATH
    export PATH=$OLD_PATH
        
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
    export PYTHONHOME=$OLD_PYTHONHOME
    popd
fi

echo "--- PHASE 4: X11 Protocol Stack ---"

# Set up environment for building against our rootfs
export PKG_CONFIG_LIBDIR="$(pwd)/rootfs/usr/lib64/pkgconfig:$(pwd)/rootfs/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$(pwd)/rootfs"
export CFLAGS="--sysroot=$(pwd)/rootfs -O2 -fPIC"
export CXXFLAGS="--sysroot=$(pwd)/rootfs -O2 -fPIC"
export LDFLAGS="--sysroot=$(pwd)/rootfs"

# 1. XORGPROTO (Standard X11 headers)
XORGPROTO_VER="2023.2"
if [ ! -f "rootfs/usr/share/pkgconfig/xproto.pc" ]; then
    echo "Building xorgproto $XORGPROTO_VER..."
    download_and_extract "https://www.x.org/archive/individual/proto/xorgproto-$XORGPROTO_VER.tar.gz" "xorgproto-$XORGPROTO_VER.tar.gz" "xorgproto-$XORGPROTO_VER"

    pushd "$DEP_DIR/xorgproto-$XORGPROTO_VER"
    ./configure --prefix=/usr --host=x86_64-linux-gnu
    make install DESTDIR=$(pwd)/../../rootfs
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 2. XTRANS (X Transport Library)
XTRANS_VER="1.5.0"
if [ ! -f "rootfs/usr/share/pkgconfig/xtrans.pc" ]; then
    echo "Building xtrans $XTRANS_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/xtrans-$XTRANS_VER.tar.gz" "xtrans-$XTRANS_VER.tar.gz" "xtrans-$XTRANS_VER"

    pushd "$DEP_DIR/xtrans-$XTRANS_VER"
    ./configure --prefix=/usr --host=x86_64-linux-gnu
    make install DESTDIR=$(pwd)/../../rootfs
    find ../../rootfs -name "*.la" -delete
    popd
fi

echo "--- PHASE 5: X11 Client Libraries ---"

# 1. LIBXAU (X Authority Library)
LIBXAU_VER="1.0.11"
if [ ! -f "rootfs/usr/lib64/libXau.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xau.pc" ]; then
    echo "Building libXau $LIBXAU_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXau-$LIBXAU_VER.tar.gz" "libXau-$LIBXAU_VER.tar.gz" "libXau-$LIBXAU_VER"
    
    pushd "$DEP_DIR/libXau-$LIBXAU_VER"
    ./configure --prefix=/usr --sysconfdir=/etc --disable-static --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 5. LIBXDMCP (X Display Manager Control Protocol Library)
LIBXDMCP_VER="1.1.5"
if [ ! -f "rootfs/usr/lib64/libXdmcp.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xdmcp.pc" ]; then
    echo "Building libXdmcp $LIBXDMCP_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXdmcp-$LIBXDMCP_VER.tar.gz" "libXdmcp-$LIBXDMCP_VER.tar.gz" "libXdmcp-$LIBXDMCP_VER"
    
    pushd "$DEP_DIR/libXdmcp-$LIBXDMCP_VER"
    ./configure --prefix=/usr --sysconfdir=/etc --disable-static --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 6. XCB-PROTO (XML descriptions for XCB)
XCB_PROTO_VER="1.16.0"
if [ ! -f "rootfs/usr/share/pkgconfig/xcb-proto.pc" ]; then
    echo "Building xcb-proto $XCB_PROTO_VER..."
    download_and_extract "https://www.x.org/archive/individual/proto/xcb-proto-$XCB_PROTO_VER.tar.gz" "xcb-proto-$XCB_PROTO_VER.tar.gz" "xcb-proto-$XCB_PROTO_VER"

    pushd "$DEP_DIR/xcb-proto-$XCB_PROTO_VER"
    ./configure --prefix=/usr --host=x86_64-linux-gnu
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 6.5. LIBPTHREAD-STUBS (Required by libxcb)
LIBPTHREAD_STUBS_VER="0.5"
if [ ! -f "rootfs/usr/lib64/pkgconfig/pthread-stubs.pc" ]; then
    echo "Building libpthread-stubs $LIBPTHREAD_STUBS_VER..."
    download_and_extract "https://xcb.freedesktop.org/dist/libpthread-stubs-$LIBPTHREAD_STUBS_VER.tar.gz" "libpthread-stubs-$LIBPTHREAD_STUBS_VER.tar.gz" "libpthread-stubs-$LIBPTHREAD_STUBS_VER"
    
    pushd "$DEP_DIR/libpthread-stubs-$LIBPTHREAD_STUBS_VER"
    ./configure --prefix=/usr --libdir=/usr/lib64 --host=x86_64-linux-gnu
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

# 7. LIBXCB (X C-language Binding)
LIBXCB_VER="1.16"
if [ ! -f "rootfs/usr/lib64/libxcb.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xcb.pc" ]; then
    echo "Building libxcb $LIBXCB_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libxcb-$LIBXCB_VER.tar.gz" "libxcb-$LIBXCB_VER.tar.gz" "libxcb-$LIBXCB_VER"
    
    pushd "$DEP_DIR/libxcb-$LIBXCB_VER"
    # We point to our rootfs pkg-config to find xproto, xau, xdmcp
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    ./configure --prefix=/usr --sysconfdir=/etc --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Fix .la files
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 7.4. XCB-UTIL (Base utility library for XCB)
XCB_UTIL_VER="0.4.1"
if [ ! -f "rootfs/usr/lib64/libxcb-util.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xcb-util.pc" ]; then
    echo "Building xcb-util $XCB_UTIL_VER..."
    download_and_extract "https://xcb.freedesktop.org/dist/xcb-util-$XCB_UTIL_VER.tar.gz" "xcb-util-$XCB_UTIL_VER.tar.gz" "xcb-util-$XCB_UTIL_VER"
    
    pushd "$DEP_DIR/xcb-util-$XCB_UTIL_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 7.5. XCB-UTIL-KEYSYMS (Required by Mesa)
XCB_UTIL_KEYSYMS_VER="0.4.1"
if [ ! -f "rootfs/usr/lib64/libxcb-keysyms.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xcb-keysyms.pc" ]; then
    echo "Building xcb-util-keysyms $XCB_UTIL_KEYSYMS_VER..."
    download_and_extract "https://xcb.freedesktop.org/dist/xcb-util-keysyms-$XCB_UTIL_KEYSYMS_VER.tar.gz" "xcb-util-keysyms-$XCB_UTIL_KEYSYMS_VER.tar.gz" "xcb-util-keysyms-$XCB_UTIL_KEYSYMS_VER"
    
    pushd "$DEP_DIR/xcb-util-keysyms-$XCB_UTIL_KEYSYMS_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 8. LIBX11 (The primary X11 library)
LIBX11_VER="1.8.7"
if [ ! -f "rootfs/usr/lib64/libX11.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/x11.pc" ]; then
    echo "Building libX11 $LIBX11_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libX11-$LIBX11_VER.tar.gz" "libX11-$LIBX11_VER.tar.gz" "libX11-$LIBX11_VER"
    
    pushd "$DEP_DIR/libX11-$LIBX11_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    ./configure --prefix=/usr --sysconfdir=/etc --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 9. LIBXEXT (X Extensions Library)
LIBXEXT_VER="1.3.5"
if [ ! -f "rootfs/usr/lib64/libXext.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xext.pc" ]; then
    echo "Building libXext $LIBXEXT_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXext-$LIBXEXT_VER.tar.gz" "libXext-$LIBXEXT_VER.tar.gz" "libXext-$LIBXEXT_VER"
    
    pushd "$DEP_DIR/libXext-$LIBXEXT_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    ./configure --prefix=/usr --sysconfdir=/etc --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Fix .la files
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 9.5. LIBXXF86VM (X11 Free86 Video Mode extension library, required by Mesa)
LIBXXF86VM_VER="1.1.5"
if [ ! -f "rootfs/usr/lib64/libXxf86vm.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xxf86vm.pc" ]; then
    echo "Building libXxf86vm $LIBXXF86VM_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXxf86vm-$LIBXXF86VM_VER.tar.gz" "libXxf86vm-$LIBXXF86VM_VER.tar.gz" "libXxf86vm-$LIBXXF86VM_VER"
    
    pushd "$DEP_DIR/libXxf86vm-$LIBXXF86VM_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 9.5. LIBXPM (X Pixmap Library)
LIBXPM_VER="3.5.17"
if [ ! -f "rootfs/usr/lib64/libXpm.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xpm.pc" ]; then
    echo "Building libXpm $LIBXPM_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXpm-$LIBXPM_VER.tar.gz" "libXpm-$LIBXPM_VER.tar.gz" "libXpm-$LIBXPM_VER"
    
    pushd "$DEP_DIR/libXpm-$LIBXPM_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 11. LIBXRENDER (X Render Extension Library)
LIBXRENDER_VER="0.9.11"
if [ ! -f "rootfs/usr/lib64/libXrender.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xrender.pc" ]; then
    echo "Building libXrender $LIBXRENDER_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXrender-$LIBXRENDER_VER.tar.gz" "libXrender-$LIBXRENDER_VER.tar.gz" "libXrender-$LIBXRENDER_VER"
    
    pushd "$DEP_DIR/libXrender-$LIBXRENDER_VER"
    
    # Patch Glyph.c to fix missing semicolons in BufAlloc macros
    echo "Patching libXrender Glyph.c..."
    sed -i '483s/BufAlloc (xGlyphElt \*, elt, SIZEOF(xGlyphElt))/BufAlloc (xGlyphElt *, elt, SIZEOF(xGlyphElt));/' src/Glyph.c
    sed -i '597s/BufAlloc (xGlyphElt \*, elt, SIZEOF(xGlyphElt))/BufAlloc (xGlyphElt *, elt, SIZEOF(xGlyphElt));/' src/Glyph.c
    sed -i '706s/BufAlloc (xGlyphElt \*, elt, SIZEOF(xGlyphElt))/BufAlloc (xGlyphElt *, elt, SIZEOF(xGlyphElt));/' src/Glyph.c

    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 12. LIBXFIXES (X Fixes Extension Library)
LIBXFIXES_VER="6.0.1"
if [ ! -f "rootfs/usr/lib64/libXfixes.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xfixes.pc" ]; then
    echo "Building libXfixes $LIBXFIXES_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXfixes-$LIBXFIXES_VER.tar.gz" "libXfixes-$LIBXFIXES_VER.tar.gz" "libXfixes-$LIBXFIXES_VER"
    
    pushd "$DEP_DIR/libXfixes-$LIBXFIXES_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 13. LIBXDAMAGE (X Damage Extension Library)
LIBXDAMAGE_VER="1.1.6"
if [ ! -f "rootfs/usr/lib64/libXdamage.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xdamage.pc" ]; then
    echo "Building libXdamage $LIBXDAMAGE_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXdamage-$LIBXDAMAGE_VER.tar.gz" "libXdamage-$LIBXDAMAGE_VER.tar.gz" "libXdamage-$LIBXDAMAGE_VER"
    
    pushd "$DEP_DIR/libXdamage-$LIBXDAMAGE_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 14. LIBXCOMPOSITE (X Composite Extension Library)
LIBXCOMPOSITE_VER="0.4.6"
if [ ! -f "rootfs/usr/lib64/libXcomposite.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xcomposite.pc" ]; then
    echo "Building libXcomposite $LIBXCOMPOSITE_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXcomposite-$LIBXCOMPOSITE_VER.tar.gz" "libXcomposite-$LIBXCOMPOSITE_VER.tar.gz" "libXcomposite-$LIBXCOMPOSITE_VER"
    
    pushd "$DEP_DIR/libXcomposite-$LIBXCOMPOSITE_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 15. LIBXCURSOR (X Cursor Management Library)
LIBXCURSOR_VER="1.2.1"
if [ ! -f "rootfs/usr/lib64/libXcursor.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xcursor.pc" ]; then
    echo "Building libXcursor $LIBXCURSOR_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXcursor-$LIBXCURSOR_VER.tar.gz" "libXcursor-$LIBXCURSOR_VER.tar.gz" "libXcursor-$LIBXCURSOR_VER"
    
    pushd "$DEP_DIR/libXcursor-$LIBXCURSOR_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 16. LIBXRANDR (X Resize, Rotate and Reflection Extension Library)
LIBXRANDR_VER="1.5.4"
if [ ! -f "rootfs/usr/lib64/libXrandr.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xrandr.pc" ]; then
    echo "Building libXrandr $LIBXRANDR_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXrandr-$LIBXRANDR_VER.tar.gz" "libXrandr-$LIBXRANDR_VER.tar.gz" "libXrandr-$LIBXRANDR_VER"
    
    pushd "$DEP_DIR/libXrandr-$LIBXRANDR_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 17. LIBXI (X Input Extension Library)
LIBXI_VER="1.8.1"
if [ ! -f "rootfs/usr/lib64/libXi.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xi.pc" ]; then
    echo "Building libXi $LIBXI_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXi-$LIBXI_VER.tar.gz" "libXi-$LIBXI_VER.tar.gz" "libXi-$LIBXI_VER"
    
    pushd "$DEP_DIR/libXi-$LIBXI_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 17.5. LIBXTST (X Test Extension Library)
LIBXTST_VER="1.2.4"
if [ ! -f "rootfs/usr/lib64/libXtst.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xtst.pc" ]; then
    echo "Building libXtst $LIBXTST_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXtst-$LIBXTST_VER.tar.gz" "libXtst-$LIBXTST_VER.tar.gz" "libXtst-$LIBXTST_VER"
    
    pushd "$DEP_DIR/libXtst-$LIBXTST_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 18. LIBXINERAMA (X Inerama Extension Library)
LIBXINERAMA_VER="1.1.5"
if [ ! -f "rootfs/usr/lib64/libXinerama.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xinerama.pc" ]; then
    echo "Building libXinerama $LIBXINERAMA_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXinerama-$LIBXINERAMA_VER.tar.gz" "libXinerama-$LIBXINERAMA_VER.tar.gz" "libXinerama-$LIBXINERAMA_VER"
    
    pushd "$DEP_DIR/libXinerama-$LIBXINERAMA_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

echo "--- PHASE 6: Graphics & Font Primitives ---"

# 1. LIBPNG (PNG support)
LIBPNG_VER="1.6.40"
if [ ! -f "rootfs/usr/lib64/libpng.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/libpng16.pc" ]; then
    echo "Building libpng $LIBPNG_VER..."
    download_and_extract "https://downloads.sourceforge.net/libpng/libpng-$LIBPNG_VER.tar.xz" "libpng-$LIBPNG_VER.tar.xz" "libpng-$LIBPNG_VER"
    
    pushd "$DEP_DIR/libpng-$LIBPNG_VER"
    ./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 2. LIBJPEG-TURBO (JPEG support)
LIBJPEG_TURBO_VER="3.0.1"
if [ ! -f "rootfs/usr/lib64/libjpeg.so" ] || [ ! -f "rootfs/usr/include/jpeglib.h" ]; then
    echo "Building libjpeg-turbo $LIBJPEG_TURBO_VER..."
    download_and_extract "https://downloads.sourceforge.net/libjpeg-turbo/libjpeg-turbo-$LIBJPEG_TURBO_VER.tar.gz" "libjpeg-turbo-$LIBJPEG_TURBO_VER.tar.gz" "libjpeg-turbo-$LIBJPEG_TURBO_VER"
    
    pushd "$DEP_DIR/libjpeg-turbo-$LIBJPEG_TURBO_VER"
    mkdir -p build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 -DENABLE_STATIC=FALSE ..
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../../rootfs
    popd
fi

# 3. LIBTIFF (TIFF support)
LIBTIFF_VER="4.6.0"
if [ ! -f "rootfs/usr/lib64/libtiff.so" ] || [ ! -f "rootfs/usr/include/tiff.h" ]; then
    echo "Building libtiff $LIBTIFF_VER..."
    download_and_extract "https://download.osgeo.org/libtiff/tiff-$LIBTIFF_VER.tar.gz" "tiff-$LIBTIFF_VER.tar.gz" "tiff-$LIBTIFF_VER"
    
    pushd "$DEP_DIR/tiff-$LIBTIFF_VER"
    ./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --host=x86_64-linux-gnu
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

# 4. FREETYPE (Font engine)
FREETYPE_VER="2.13.2"
if [ ! -f "rootfs/usr/lib64/libfreetype.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/freetype2.pc" ]; then
    echo "Building freetype $FREETYPE_VER..."
    download_and_extract "https://download-mirror.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.xz" "freetype-$FREETYPE_VER.tar.xz" "freetype-$FREETYPE_VER"
    
    pushd "$DEP_DIR/freetype-$FREETYPE_VER"
    ./configure --prefix=/usr --libdir=/usr/lib64 --disable-static \
        --without-harfbuzz --without-bzip2 --without-brotli --with-png --with-zlib
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 5. FONTCONFIG (Font configuration)
FONTCONFIG_VER="2.15.0"
if [ ! -f "rootfs/usr/lib64/libfontconfig.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/fontconfig.pc" ]; then
    echo "Building fontconfig $FONTCONFIG_VER..."
    download_and_extract "https://www.freedesktop.org/software/fontconfig/release/fontconfig-$FONTCONFIG_VER.tar.xz" "fontconfig-$FONTCONFIG_VER.tar.xz" "fontconfig-$FONTCONFIG_VER"
    
    pushd "$DEP_DIR/fontconfig-$FONTCONFIG_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static --disable-docs
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 6. PIXMAN (Pixel manipulation)
PIXMAN_VER="0.42.2"
if [ ! -f "rootfs/usr/lib64/libpixman-1.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/pixman-1.pc" ]; then
    echo "Building pixman $PIXMAN_VER..."
    download_and_extract "https://www.cairographics.org/releases/pixman-$PIXMAN_VER.tar.gz" "pixman-$PIXMAN_VER.tar.gz" "pixman-$PIXMAN_VER"
    
    pushd "$DEP_DIR/pixman-$PIXMAN_VER"
    ./configure --prefix=/usr --disable-static --disable-gtk --disable-libpng --disable-openmp
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 21. LIBXFT (FreeType-based font drawing library for X)
LIBXFT_VER="2.3.8"
if [ ! -f "rootfs/usr/lib64/libXft.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xft.pc" ]; then
    echo "Building libXft $LIBXFT_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXft-$LIBXFT_VER.tar.gz" "libXft-$LIBXFT_VER.tar.gz" "libXft-$LIBXFT_VER"
    
    pushd "$DEP_DIR/libXft-$LIBXFT_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 22. LIBICE (Inter-Client Exchange Library)
LIBICE_VER="1.1.1"
if [ ! -f "rootfs/usr/lib64/libICE.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/ice.pc" ]; then
    echo "Building libICE $LIBICE_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libICE-$LIBICE_VER.tar.gz" "libICE-$LIBICE_VER.tar.gz" "libICE-$LIBICE_VER"
    
    pushd "$DEP_DIR/libICE-$LIBICE_VER"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 23. LIBSM (Session Management Library)
LIBSM_VER="1.2.4"
if [ ! -f "rootfs/usr/lib64/libSM.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/sm.pc" ]; then
    echo "Building libSM $LIBSM_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libSM-$LIBSM_VER.tar.gz" "libSM-$LIBSM_VER.tar.gz" "libSM-$LIBSM_VER"
    
    pushd "$DEP_DIR/libSM-$LIBSM_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 24. LIBXT (X Toolkit Intrinsics Library)
LIBXT_VER="1.3.0"
if [ ! -f "rootfs/usr/lib64/libXt.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xt.pc" ]; then
    echo "Building libXt $LIBXT_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXt-$LIBXT_VER.tar.gz" "libXt-$LIBXT_VER.tar.gz" "libXt-$LIBXT_VER"
    
    pushd "$DEP_DIR/libXt-$LIBXT_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 25. LIBXMU (X Miscellaneous Utilities Library)
LIBXMU_VER="1.1.4"
if [ ! -f "rootfs/usr/lib64/libXmu.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xmu.pc" ]; then
    echo "Building libXmu $LIBXMU_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXmu-$LIBXMU_VER.tar.gz" "libXmu-$LIBXMU_VER.tar.gz" "libXmu-$LIBXMU_VER"
    
    pushd "$DEP_DIR/libXmu-$LIBXMU_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 25.5. LIBXAW (X Athena Widget Set)
LIBXAW_VER="1.0.15"
if [ ! -f "rootfs/usr/lib64/libXaw.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xaw7.pc" ]; then
    echo "Building libXaw $LIBXAW_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXaw-$LIBXAW_VER.tar.gz" "libXaw-$LIBXAW_VER.tar.gz" "libXaw-$LIBXAW_VER"
    
    pushd "$DEP_DIR/libXaw-$LIBXAW_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 26. LIBXKBFILE (X Keyboard File Library)
LIBXKBFILE_VER="1.1.2"
if [ ! -f "rootfs/usr/lib64/libxkbfile.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xkbfile.pc" ]; then
    echo "Building libxkbfile $LIBXKBFILE_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libxkbfile-$LIBXKBFILE_VER.tar.gz" "libxkbfile-$LIBXKBFILE_VER.tar.gz" "libxkbfile-$LIBXKBFILE_VER"
    
    pushd "$DEP_DIR/libxkbfile-$LIBXKBFILE_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 27. LIBFONTENC (Font Encoding Library)
LIBFONTENC_VER="1.1.7"
if [ ! -f "rootfs/usr/lib64/libfontenc.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/fontenc.pc" ]; then
    echo "Building libfontenc $LIBFONTENC_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libfontenc-$LIBFONTENC_VER.tar.gz" "libfontenc-$LIBFONTENC_VER.tar.gz" "libfontenc-$LIBFONTENC_VER"
    
    pushd "$DEP_DIR/libfontenc-$LIBFONTENC_VER"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 28. LIBXFONT2 (X Font Library v2)
LIBXFONT2_VER="2.0.6"
if [ ! -f "rootfs/usr/lib64/libXfont2.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xfont2.pc" ]; then
    echo "Building libXfont2 $LIBXFONT2_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libXfont2-$LIBXFONT2_VER.tar.gz" "libXfont2-$LIBXFONT2_VER.tar.gz" "libXfont2-$LIBXFONT2_VER"
    
    pushd "$DEP_DIR/libXfont2-$LIBXFONT2_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 29. XKBCOMP (X Keyboard Compiler)
XKBCOMP_VER="1.4.6"
if [ ! -f "rootfs/usr/bin/xkbcomp" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xkbcomp.pc" ]; then
    echo "Building xkbcomp $XKBCOMP_VER..."
    download_and_extract "https://www.x.org/archive/individual/app/xkbcomp-$XKBCOMP_VER.tar.gz" "xkbcomp-$XKBCOMP_VER.tar.gz" "xkbcomp-$XKBCOMP_VER"
    
    pushd "$DEP_DIR/xkbcomp-$XKBCOMP_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 30. LIBPCIACCESS (PCI Access Library)
LIBPCIACCESS_VER="0.17"
if [ ! -f "rootfs/usr/lib64/libpciaccess.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/pciaccess.pc" ]; then
    echo "Building libpciaccess $LIBPCIACCESS_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libpciaccess-$LIBPCIACCESS_VER.tar.xz" "libpciaccess-$LIBPCIACCESS_VER.tar.xz" "libpciaccess-$LIBPCIACCESS_VER"
    
    pushd "$DEP_DIR/libpciaccess-$LIBPCIACCESS_VER"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 31. LIBXSHMFENCE (Shared Memory Fence Library)
LIBXSHMFENCE_VER="1.3.2"
if [ ! -f "rootfs/usr/lib64/libxshmfence.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xshmfence.pc" ]; then
    echo "Building libxshmfence $LIBXSHMFENCE_VER..."
    download_and_extract "https://www.x.org/archive/individual/lib/libxshmfence-$LIBXSHMFENCE_VER.tar.gz" "libxshmfence-$LIBXSHMFENCE_VER.tar.gz" "libxshmfence-$LIBXSHMFENCE_VER"
    
    pushd "$DEP_DIR/libxshmfence-$LIBXSHMFENCE_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 31.5. FONT-UTIL (Required for Xorg server)
FONT_UTIL_VER="1.4.1"
if [ ! -f "rootfs/usr/lib64/pkgconfig/fontutil.pc" ]; then
    echo "Building font-util $FONT_UTIL_VER..."
    download_and_extract "https://www.x.org/archive/individual/font/font-util-$FONT_UTIL_VER.tar.xz" "font-util-$FONT_UTIL_VER.tar.xz" "font-util-$FONT_UTIL_VER"
    
    pushd "$DEP_DIR/font-util-$FONT_UTIL_VER"
    ./configure --prefix=/usr
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 32. EUDEV (Provides libudev for device discovery)
EUDEV_VER="3.2.14"
if [ ! -f "rootfs/usr/lib64/libudev.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/libudev.pc" ]; then
    echo "Building eudev $EUDEV_VER..."
    download_and_extract "https://github.com/eudev-project/eudev/releases/download/v$EUDEV_VER/eudev-$EUDEV_VER.tar.gz" "eudev-$EUDEV_VER.tar.gz" "eudev-$EUDEV_VER"
    
    pushd "$DEP_DIR/eudev-$EUDEV_VER"
    ./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc --disable-static --disable-selinux --disable-introspection --disable-blkid --disable-kmod
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 32.5. LIBDRM (Direct Rendering Manager userspace library)
LIBDRM_VER="2.4.120"
if [ ! -f "rootfs/usr/lib64/libdrm.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/libdrm.pc" ]; then
    echo "Building libdrm $LIBDRM_VER..."
    download_and_extract "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz" "libdrm-$LIBDRM_VER.tar.xz" "libdrm-$LIBDRM_VER"
    
    pushd "$DEP_DIR/libdrm-$LIBDRM_VER"
    OLD_PYTHONHOME=$PYTHONHOME
    unset PYTHONHOME
    
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    meson setup build --prefix=/usr --libdir=lib64 \
        -Dudev=true \
        -Dintel=disabled \
        -Dradeon=disabled \
        -Damdgpu=disabled \
        -Dnouveau=disabled \
        -Dvmwgfx=enabled \
        -Dtests=false \
        -Dwerror=false
        
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    
    export PYTHONHOME=$OLD_PYTHONHOME
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
    popd
fi

# 32.6. MESA (OpenGL Implementation)
MESA_VER="24.0.0"
if [ ! -f "rootfs/usr/lib64/libGL.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/gl.pc" ]; then
    echo "Building Mesa $MESA_VER..."
    download_and_extract "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz" "mesa-$MESA_VER.tar.xz" "mesa-$MESA_VER"
    
    pushd "$DEP_DIR/mesa-$MESA_VER"
    OLD_PYTHONHOME=$PYTHONHOME
    unset PYTHONHOME
    
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    # We use swrast (software rasterizer) as the primary driver for compatibility.
    # We disable LLVM for now to keep the build simple (uses softpipe).
    # compile with virtio
    meson setup build --prefix=/usr --libdir=lib64 \
        -Dplatforms=x11 \
        -Dgallium-drivers=swrast,virtio \
        -Dvulkan-drivers= \
        -Dopengl=true \
        -Dglx=dri \
        -Degl=enabled \
        -Dgles1=enabled \
        -Dgles2=enabled \
        -Dllvm=disabled \
        -Dshared-glapi=enabled \
        -Dgbm=enabled \
        -Dbuildtype=release \
        -Dwerror=false
        
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    
    export PYTHONHOME=$OLD_PYTHONHOME
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
    popd
fi

# 32.7. LIBEPOXY (Required by Xorg glamor)
LIBEPOXY_VER="1.5.10"
if [ ! -f "rootfs/usr/lib64/libepoxy.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/epoxy.pc" ]; then
    echo "Building libepoxy $LIBEPOXY_VER..."
    download_and_extract "https://download.gnome.org/sources/libepoxy/1.5/libepoxy-$LIBEPOXY_VER.tar.xz" "libepoxy-$LIBEPOXY_VER.tar.xz" "libepoxy-$LIBEPOXY_VER"
    
    pushd "$DEP_DIR/libepoxy-$LIBEPOXY_VER"
    OLD_PYTHONHOME=$PYTHONHOME
    unset PYTHONHOME
    
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    rm -rf build
    meson setup build --prefix=/usr --libdir=lib64 -Dtests=false -Dwerror=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
    export PYTHONHOME=$OLD_PYTHONHOME
    popd
fi

# 33. XORG-SERVER (The X Window System Server)
XORG_SERVER_VER="1.20.14"
if [ ! -f "rootfs/usr/bin/Xorg" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xorg-server.pc" ]; then
    echo "Building xorg-server $XORG_SERVER_VER..."
    download_and_extract "https://www.x.org/archive/individual/xserver/xorg-server-$XORG_SERVER_VER.tar.gz" "xorg-server-$XORG_SERVER_VER.tar.gz" "xorg-server-$XORG_SERVER_VER"
    
    pushd "$DEP_DIR/xorg-server-$XORG_SERVER_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    # Configure Xorg with OpenGL support enabled
    # We use a custom 'xorg_bool' typedef to resolve conflicts between stdbool.h and X11's 'Bool bool' member.
    # We define it in dix-config.h after configure runs to ensure it's available everywhere.
    ./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc --localstatedir=/var \
        --disable-static \
        --enable-xorg \
        --disable-xwayland \
        --disable-xephyr \
        --disable-xvfb \
        --disable-xnest \
        --enable-config-udev \
        --disable-config-udev-kms \
        --disable-config-hal \
        --disable-systemd-logind \
        --enable-glx \
        --enable-dri \
        --enable-dri2 \
        --enable-dri3 \
        --enable-fbdev \
        --enable-libdrm \
        --disable-unit-tests \
        --enable-glamor \
        --disable-selective-werror \
        --with-xkb-bin-directory=/usr/bin \
        --with-xkb-path=/usr/share/X11/xkb \
        --with-xkb-output=/var/lib/xkb \
        CFLAGS="-O2 -Wno-error -Wno-redundant-decls -Dbool=xorg_bool" \
        CPPFLAGS="-Dbool=xorg_bool"
    
    make clean || true
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
    
    # Ensure X symlink exists
    ln -sf Xorg rootfs/usr/bin/X
fi

# 34. XF86-VIDEO-FBDEV (Generic Framebuffer Video Driver)
XF86_VIDEO_FBDEV_VER="0.5.0"
if [ ! -f "rootfs/usr/lib/xorg/modules/drivers/fbdev_drv.so" ]; then
    echo "Building xf86-video-fbdev $XF86_VIDEO_FBDEV_VER..."
    download_and_extract "https://www.x.org/archive/individual/driver/xf86-video-fbdev-$XF86_VIDEO_FBDEV_VER.tar.gz" "xf86-video-fbdev-$XF86_VIDEO_FBDEV_VER.tar.gz" "xf86-video-fbdev-$XF86_VIDEO_FBDEV_VER"
    
    pushd "$DEP_DIR/xf86-video-fbdev-$XF86_VIDEO_FBDEV_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 34. LIBEVDEV (Wrapper library for evdev devices)
LIBEVDEV_VER="1.13.1"
if [ ! -f "rootfs/usr/lib64/libevdev.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/libevdev.pc" ]; then
    echo "Building libevdev $LIBEVDEV_VER..."
    download_and_extract "https://www.freedesktop.org/software/libevdev/libevdev-$LIBEVDEV_VER.tar.xz" "libevdev-$LIBEVDEV_VER.tar.xz" "libevdev-$LIBEVDEV_VER"
    
    pushd "$DEP_DIR/libevdev-$LIBEVDEV_VER"
    ./configure --prefix=/usr --libdir=/usr/lib64 --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 35. MTDEV (Multitouch Protocol Translation Library)
MTDEV_VER="1.1.6"
if [ ! -f "rootfs/usr/lib64/libmtdev.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/mtdev.pc" ]; then
    echo "Building mtdev $MTDEV_VER..."
    download_and_extract "http://bitmath.org/code/mtdev/mtdev-$MTDEV_VER.tar.bz2" "mtdev-$MTDEV_VER.tar.bz2" "mtdev-$MTDEV_VER"
    
    pushd "$DEP_DIR/mtdev-$MTDEV_VER"
    ./configure --prefix=/usr --libdir=/usr/lib64 --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
fi

# 36. XF86-INPUT-EVDEV (Generic Event Device Input Driver)
XF86_INPUT_EVDEV_VER="2.10.6"
if [ ! -f "rootfs/usr/lib/xorg/modules/input/evdev_drv.so" ]; then
    echo "Building xf86-input-evdev $XF86_INPUT_EVDEV_VER..."
    download_and_extract "https://www.x.org/archive/individual/driver/xf86-input-evdev-$XF86_INPUT_EVDEV_VER.tar.gz" "xf86-input-evdev-$XF86_INPUT_EVDEV_VER.tar.gz" "xf86-input-evdev-$XF86_INPUT_EVDEV_VER"
    
    pushd "$DEP_DIR/xf86-input-evdev-$XF86_INPUT_EVDEV_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 37. XKEYBOARD-CONFIG (Keyboard configuration data)
XKEYBOARD_CONFIG_VER="2.34"
if [ ! -f "rootfs/usr/share/pkgconfig/xkeyboard-config.pc" ]; then
    echo "Building xkeyboard-config $XKEYBOARD_CONFIG_VER..."
    download_and_extract "https://www.x.org/archive/individual/data/xkeyboard-config/xkeyboard-config-$XKEYBOARD_CONFIG_VER.tar.gz" "xkeyboard-config-$XKEYBOARD_CONFIG_VER.tar.gz" "xkeyboard-config-$XKEYBOARD_CONFIG_VER"
    
    pushd "$DEP_DIR/xkeyboard-config-$XKEYBOARD_CONFIG_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --with-xkb-base=/usr/share/X11/xkb --disable-runtime-deps
    make install DESTDIR=$(pwd)/../../rootfs
    # Remove .la files (they cause issues with absolute paths in sysroot)
    find ../../rootfs -name "*.la" -delete
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 39. SETXKBMAP (Change keyboard layout in X)
SETXKBMAP_VER="1.3.4"
if [ ! -f "rootfs/usr/bin/setxkbmap" ]; then
    echo "Building setxkbmap $SETXKBMAP_VER..."
    download_and_extract "https://www.x.org/archive/individual/app/setxkbmap-$SETXKBMAP_VER.tar.xz" "setxkbmap-$SETXKBMAP_VER.tar.xz" "setxkbmap-$SETXKBMAP_VER"
    
    pushd "$DEP_DIR/setxkbmap-$SETXKBMAP_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --disable-static
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 40. XINIT (Start X sessions)
XINIT_VER="1.4.2"
if [ ! -f "rootfs/usr/bin/xinit" ]; then
    echo "Building xinit $XINIT_VER..."
    download_and_extract "https://www.x.org/archive/individual/app/xinit-$XINIT_VER.tar.gz" "xinit-$XINIT_VER.tar.gz" "xinit-$XINIT_VER"
    
    pushd "$DEP_DIR/xinit-$XINIT_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr --with-xinitdir=/etc/X11/xinit
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
    
    # Ensure startx symlink or helper exists
    ln -sf xinit rootfs/usr/bin/startx
fi

# 41. XTERM (Terminal Emulator)
XTERM_VER="389"
if [ ! -f "rootfs/usr/bin/xterm" ]; then
    echo "Building xterm $XTERM_VER..."
    download_and_extract "https://invisible-mirror.net/archives/xterm/xterm-$XTERM_VER.tgz" "xterm-$XTERM_VER.tgz" "xterm-$XTERM_VER"
    
    pushd "$DEP_DIR/xterm-$XTERM_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    # xterm needs ncurses headers
    export CFLAGS="-I$(pwd)/../../rootfs/usr/include -I$(pwd)/../../rootfs/usr/include/ncursesw"
    export LDFLAGS="-L/usr/lib64"
    ./configure --prefix=/usr --enable-wide-chars --enable-256-color --with-x --with-tty-group=tty
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

# 42. XPROP (X Property Display Utility)
XPROP_VER="1.2.6"
if [ ! -f "rootfs/usr/bin/xprop" ]; then
    echo "Building xprop $XPROP_VER..."
    download_and_extract "https://www.x.org/archive/individual/app/xprop-$XPROP_VER.tar.gz" "xprop-$XPROP_VER.tar.gz" "xprop-$XPROP_VER"
    
    pushd "$DEP_DIR/xprop-$XPROP_VER"
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    ./configure --prefix=/usr
    make -j$JOBS
    make install DESTDIR=$(pwd)/../../rootfs
    popd
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
fi

# 43. GSETTINGS-DESKTOP-SCHEMAS
GSETTINGS_SCHEMAS_VER="42.0"
if [ ! -d "rootfs/usr/share/glib-2.0/schemas" ] || [ ! -f "rootfs/usr/share/pkgconfig/gsettings-desktop-schemas.pc" ]; then
    echo "Building gsettings-desktop-schemas $GSETTINGS_SCHEMAS_VER..."
    download_and_extract "https://download.gnome.org/sources/gsettings-desktop-schemas/42/gsettings-desktop-schemas-$GSETTINGS_SCHEMAS_VER.tar.xz" "gsettings-desktop-schemas-$GSETTINGS_SCHEMAS_VER.tar.xz" "gsettings-desktop-schemas-$GSETTINGS_SCHEMAS_VER"
    
    pushd "$DEP_DIR/gsettings-desktop-schemas-$GSETTINGS_SCHEMAS_VER"
    OLD_PYTHONHOME=$PYTHONHOME
    unset PYTHONHOME
    
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    meson setup build --prefix=/usr --libdir=lib64 -Dintrospection=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
    export PYTHONHOME=$OLD_PYTHONHOME
    popd
fi

echo "--- PHASE 7: Rendering Stack ---"

# 1. CAIRO
CAIRO_VER="1.18.0"
if [ ! -f "rootfs/usr/lib64/libcairo.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/cairo.pc" ]; then
    echo "Building cairo $CAIRO_VER..."
    download_and_extract "https://cairographics.org/releases/cairo-$CAIRO_VER.tar.xz" "cairo-$CAIRO_VER.tar.xz" "cairo-$CAIRO_VER"
    pushd "$DEP_DIR/cairo-$CAIRO_VER"
    meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dtee=enabled -Dxcb=enabled -Dxlib=enabled -Dtests=disabled -Dwerror=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    popd
fi

# 2. HARFBUZZ (Text shaping engine)
HARFBUZZ_VER="8.3.0"
if [ ! -f "rootfs/usr/lib64/libharfbuzz.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/harfbuzz.pc" ]; then
    echo "Building harfbuzz $HARFBUZZ_VER..."
    download_and_extract "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VER/harfbuzz-$HARFBUZZ_VER.tar.xz" "harfbuzz-$HARFBUZZ_VER.tar.xz" "harfbuzz-$HARFBUZZ_VER"
    pushd "$DEP_DIR/harfbuzz-$HARFBUZZ_VER"
    OLD_PYTHONHOME=$PYTHONHOME
    unset PYTHONHOME
    meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dglib=enabled -Dfreetype=enabled -Dgobject=enabled -Dintrospection=disabled -Dcairo=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dwerror=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    export PYTHONHOME=$OLD_PYTHONHOME
    popd
fi

# 3. FRIBIDI (Bidirectional algorithm)
FRIBIDI_VER="1.0.13"
if [ ! -f "rootfs/usr/lib64/libfribidi.so" ] || [ ! -f "rootfs/usr/include/fribidi/fribidi.h" ]; then
    echo "Building fribidi $FRIBIDI_VER..."
    download_and_extract "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VER/fribidi-$FRIBIDI_VER.tar.xz" "fribidi-$FRIBIDI_VER.tar.xz" "fribidi-$FRIBIDI_VER"
    pushd "$DEP_DIR/fribidi-$FRIBIDI_VER"
    mkdir -p build && cd build
    meson setup --prefix=/usr --libdir=lib64 -Ddocs=false -Dwerror=false ..
    ninja
    DESTDIR=$(pwd)/../../../rootfs ninja install
    popd
fi

# 4. PANGO
PANGO_VER="1.50.14"
if [ ! -f "rootfs/usr/lib64/libpango-1.0.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/pango.pc" ]; then
    echo "Building pango $PANGO_VER..."
    download_and_extract "https://download.gnome.org/sources/pango/1.50/pango-$PANGO_VER.tar.xz" "pango-$PANGO_VER.tar.xz" "pango-$PANGO_VER"
    pushd "$DEP_DIR/pango-$PANGO_VER"
    meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dintrospection=disabled -Dwerror=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    popd
fi

echo "--- PHASE 8: Assets & Accessibility ---"

# 1. SHARED-MIME-INFO
SHARED_MIME_INFO_VER="2.4"
if [ ! -f "rootfs/usr/share/mime/magic" ]; then
    echo "Building shared-mime-info $SHARED_MIME_INFO_VER..."
    download_and_extract "https://gitlab.freedesktop.org/xdg/shared-mime-info/-/archive/$SHARED_MIME_INFO_VER/shared-mime-info-$SHARED_MIME_INFO_VER.tar.gz" "shared-mime-info-$SHARED_MIME_INFO_VER.tar.gz" "shared-mime-info-$SHARED_MIME_INFO_VER"
    pushd "$DEP_DIR/shared-mime-info-$SHARED_MIME_INFO_VER"
    OLD_PYTHONHOME=$PYTHONHOME
    unset PYTHONHOME
    meson setup build --prefix=/usr --libdir=lib64 -Dupdate-mimedb=true -Dwerror=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    export PYTHONHOME=$OLD_PYTHONHOME
    popd
fi

# 2. GDK-PIXBUF
GDK_PIXBUF_VER="2.42.10"
if [ ! -f "rootfs/usr/lib64/libgdk_pixbuf-2.0.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/gdk-pixbuf-2.0.pc" ]; then
    echo "Building gdk-pixbuf $GDK_PIXBUF_VER..."
    download_and_extract "https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-$GDK_PIXBUF_VER.tar.xz" "gdk-pixbuf-$GDK_PIXBUF_VER.tar.xz" "gdk-pixbuf-$GDK_PIXBUF_VER"
    pushd "$DEP_DIR/gdk-pixbuf-$GDK_PIXBUF_VER"
    meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dintrospection=disabled -Dman=false -Dwerror=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    popd
fi

# 3. AT-SPI2-CORE
AT_SPI2_CORE_VER="2.38.0"
if [ ! -f "rootfs/usr/lib64/libatspi.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/atspi-2.pc" ]; then
    echo "Building at-spi2-core $AT_SPI2_CORE_VER..."
    download_and_extract "https://download.gnome.org/sources/at-spi2-core/2.38/at-spi2-core-$AT_SPI2_CORE_VER.tar.xz" "at-spi2-core-$AT_SPI2_CORE_VER.tar.xz" "at-spi2-core-$AT_SPI2_CORE_VER"
    pushd "$DEP_DIR/at-spi2-core-$AT_SPI2_CORE_VER"
    OLD_PYTHONHOME=$PYTHONHOME
    unset PYTHONHOME
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    # Point to our built python and libraries
    OLD_LD_LIBRARY_PATH=$LD_LIBRARY_PATH
    OLD_PATH=$PATH
    export LD_LIBRARY_PATH="$(pwd)/../../rootfs/usr/lib64:$LD_LIBRARY_PATH"
    export PATH="$(pwd)/../../rootfs/usr/bin:$PATH"

    env -u LD_LIBRARY_PATH meson setup build --prefix=/usr --libdir=lib64 -Dintrospection=no -Dx11=yes -Dwerror=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    
    export LD_LIBRARY_PATH=$OLD_LD_LIBRARY_PATH
    export PATH=$OLD_PATH
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
    export PYTHONHOME=$OLD_PYTHONHOME
    popd
fi

# 4. AT-SPI2-ATK
AT_SPI2_ATK_VER="2.38.0"
if [ ! -f "rootfs/usr/lib64/libatk-bridge-2.0.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/atk-bridge-2.0.pc" ]; then
    echo "Building at-spi2-atk $AT_SPI2_ATK_VER..."
    download_and_extract "https://download.gnome.org/sources/at-spi2-atk/2.38/at-spi2-atk-$AT_SPI2_ATK_VER.tar.xz" "at-spi2-atk-$AT_SPI2_ATK_VER.tar.xz" "at-spi2-atk-$AT_SPI2_ATK_VER"
    pushd "$DEP_DIR/at-spi2-atk-$AT_SPI2_ATK_VER"
    OLD_PYTHONHOME=$PYTHONHOME
    unset PYTHONHOME
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    # Point to our built python and libraries
    OLD_LD_LIBRARY_PATH=$LD_LIBRARY_PATH
    OLD_PATH=$PATH
    export LD_LIBRARY_PATH="$(pwd)/../../rootfs/usr/lib64:$LD_LIBRARY_PATH"
    export PATH="$(pwd)/../../rootfs/usr/bin:$PATH"

    env -u LD_LIBRARY_PATH meson setup build --prefix=/usr --libdir=lib64 -Dtests=false -Dwerror=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    
    export LD_LIBRARY_PATH=$OLD_LD_LIBRARY_PATH
    export PATH=$OLD_PATH
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
    export PYTHONHOME=$OLD_PYTHONHOME
    popd
fi

# 5. ATK
ATK_VER="2.38.0"
if [ ! -f "rootfs/usr/lib64/libatk-1.0.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/atk.pc" ]; then
    echo "Building atk $ATK_VER..."
    download_and_extract "https://download.gnome.org/sources/atk/2.38/atk-$ATK_VER.tar.xz" "atk-$ATK_VER.tar.xz" "atk-$ATK_VER"
    pushd "$DEP_DIR/atk-$ATK_VER"
    meson setup build --prefix=/usr --libdir=lib64 -Dintrospection=false -Dwerror=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    popd
fi

echo "--- PHASE 9: Final Pre-Requisites ---"

# 2. LIBXKBCOMMON
LIBXKBCOMMON_VER="1.6.0"
if [ ! -f "rootfs/usr/lib64/libxkbcommon.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/xkbcommon.pc" ]; then
    echo "Building libxkbcommon $LIBXKBCOMMON_VER..."
    download_and_extract "https://xkbcommon.org/download/libxkbcommon-$LIBXKBCOMMON_VER.tar.xz" "libxkbcommon-$LIBXKBCOMMON_VER.tar.xz" "libxkbcommon-$LIBXKBCOMMON_VER"
    pushd "$DEP_DIR/libxkbcommon-$LIBXKBCOMMON_VER"
    OLD_PYTHONHOME=$PYTHONHOME
    unset PYTHONHOME
    export PKG_CONFIG_LIBDIR="$(pwd)/../../rootfs/usr/lib64/pkgconfig:$(pwd)/../../rootfs/usr/share/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$(pwd)/../../rootfs"
    
    # Point to our built python and libraries
    OLD_LD_LIBRARY_PATH=$LD_LIBRARY_PATH
    OLD_PATH=$PATH
    export LD_LIBRARY_PATH="$(pwd)/../../rootfs/usr/lib64:$LD_LIBRARY_PATH"
    export PATH="$(pwd)/../../rootfs/usr/bin:$PATH"

    env -u LD_LIBRARY_PATH meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Denable-x11=true -Denable-wayland=false -Denable-docs=false -Dwerror=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    
    export LD_LIBRARY_PATH=$OLD_LD_LIBRARY_PATH
    export PATH=$OLD_PATH
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
    export PYTHONHOME=$OLD_PYTHONHOME
    popd
fi

# 3. HICOLOR-ICON-THEME
HICOLOR_ICON_THEME_VER="0.17"
if [ ! -d "rootfs/usr/share/icons/hicolor" ]; then
    echo "Building hicolor-icon-theme $HICOLOR_ICON_THEME_VER..."
    download_and_extract "https://icon-theme.freedesktop.org/releases/hicolor-icon-theme-$HICOLOR_ICON_THEME_VER.tar.xz" "hicolor-icon-theme-$HICOLOR_ICON_THEME_VER.tar.xz" "hicolor-icon-theme-$HICOLOR_ICON_THEME_VER"
    pushd "$DEP_DIR/hicolor-icon-theme-$HICOLOR_ICON_THEME_VER"
    ./configure --prefix=/usr
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

# 4. ADWAITA-ICON-THEME
ADWAITA_ICON_THEME_VER="42.0"
if [ ! -d "rootfs/usr/share/icons/Adwaita" ]; then
    echo "Building adwaita-icon-theme $ADWAITA_ICON_THEME_VER..."
    download_and_extract "https://download.gnome.org/sources/adwaita-icon-theme/42/adwaita-icon-theme-$ADWAITA_ICON_THEME_VER.tar.xz" "adwaita-icon-theme-$ADWAITA_ICON_THEME_VER.tar.xz" "adwaita-icon-theme-$ADWAITA_ICON_THEME_VER"
    pushd "$DEP_DIR/adwaita-icon-theme-$ADWAITA_ICON_THEME_VER"
    ./configure --prefix=/usr
    make install DESTDIR=$(pwd)/../../rootfs
    popd
fi

echo "--- PHASE 10: GTK+ 3 ---"

# 1. GTK+ 3
GTK3_VER="3.24.41"
if [ ! -f "rootfs/usr/lib64/libgtk-3.so" ] || [ ! -f "rootfs/usr/lib64/pkgconfig/gtk+-3.0.pc" ]; then
    echo "Building gtk+ 3 $GTK3_VER..."
    download_and_extract "https://download.gnome.org/sources/gtk+/3.24/gtk+-$GTK3_VER.tar.xz" "gtk+-$GTK3_VER.tar.xz" "gtk+-$GTK3_VER"    
    pushd "$DEP_DIR/gtk+-$GTK3_VER"
    meson setup build --prefix=/usr --libdir=lib64 -Ddefault_library=shared -Dintrospection=false -Ddemos=false -Dexamples=false -Dtests=false -Dwayland_backend=false -Dx11_backend=true -Dwerror=false
    ninja -C build
    DESTDIR=$(pwd)/../../rootfs ninja -C build install
    popd
fi

# --- POST-GTK FIXES (Critical for runtime) ---
echo "Compiling GLib schemas in rootfs..."
if [ -x "rootfs/usr/bin/glib-compile-schemas" ]; then
    # We use our built tool and libraries to ensure compatibility
    LD_LIBRARY_PATH="$(pwd)/rootfs/usr/lib64" ./rootfs/usr/bin/glib-compile-schemas "$(pwd)/rootfs/usr/share/glib-2.0/schemas"
fi

echo "Updating Mime Database in rootfs..."
if [ -x "rootfs/usr/bin/update-mime-database" ]; then
    LD_LIBRARY_PATH="$(pwd)/rootfs/usr/lib64" ./rootfs/usr/bin/update-mime-database "$(pwd)/rootfs/usr/share/mime"
fi

unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_ALLOW_SYSTEM_CFLAGS PKG_CONFIG_ALLOW_SYSTEM_LIBS LD_LIBRARY_PATH PYTHONHOME

echo "Setting permissions..."
chmod u+s rootfs/bin/apps/system/su rootfs/bin/apps/system/sudo
mkdir -p rootfs/bin/apps
g++ -static -O2 -I src -o rootfs/bin/apps/snake packages/snake/snake.cpp
strip rootfs/bin/apps/snake

echo "--- 1.2 Compiling Bash (Script Support) ---"
BASH_VER="5.2.21"
# Check if we already compiled it to save time
if [ ! -f "$DEP_DIR/bash-$BASH_VER/bash" ]; then
    echo "Downloading and Compiling Bash..."
    download_and_extract "https://ftp.gnu.org/gnu/bash/bash-$BASH_VER.tar.gz" "bash-$BASH_VER.tar.gz" "bash-$BASH_VER"

    pushd "$DEP_DIR/bash-$BASH_VER"
    # Configure for static build, minimal features for scripting
    ./configure --enable-static-link --without-bash-malloc --disable-nls \
        --disable-shared --disable-curses LDFLAGS="-static"
    make -j$JOBS
    popd
fi
# Install to rootfs
cp "$DEP_DIR/bash-$BASH_VER/bash" rootfs/bin/bash
strip rootfs/bin/bash
ln -sf bash rootfs/bin/sh

echo "--- 1.3 Compiling GNU Tools (Nano, Grep, Ncurses) ---"

# 1. NCURSES (Required for Nano)
NCURSES_VER="6.4"
# Check for either standard or wide library to prevent rebuild loops
if [ ! -f "$DEP_DIR/ncurses-$NCURSES_VER/lib/libncurses.a" ] && [ ! -f "$DEP_DIR/ncurses-$NCURSES_VER/lib/libncursesw.a" ]; then
    echo "Downloading and Compiling Ncurses..."
    download_and_extract "https://ftp.gnu.org/pub/gnu/ncurses/ncurses-$NCURSES_VER.tar.gz" "ncurses-$NCURSES_VER.tar.gz" "ncurses-$NCURSES_VER"
    
    pushd "$DEP_DIR/ncurses-$NCURSES_VER"
    # Configure for static, minimal, no C++ bindings, standard linux terminal support
    ./configure --disable-shared --enable-static --without-cxx --without-ada \
        --without-progs --without-tests --enable-widec --with-terminfo-dirs="/usr/share/terminfo" \
        --with-default-terminfo-dir="/usr/share/terminfo" --with-term-lib=tinfo
        
    # Create compat symlink so 'libncurses.a' exists for the check and for packages linking -lncurses
    if [ -f "lib/libncursesw.a" ]; then
        ln -sf libncursesw.a lib/libncurses.a
    fi
    make -j$JOBS
    popd
fi

# 2. NANO (Text Editor)
NANO_VER="7.2"
if [ ! -f "$DEP_DIR/nano-$NANO_VER/src/nano" ]; then
    echo "Downloading and Compiling Nano..."
    download_and_extract "https://www.nano-editor.org/dist/v7/nano-$NANO_VER.tar.gz" "nano-$NANO_VER.tar.gz" "nano-$NANO_VER"
    
    pushd "$DEP_DIR/nano-$NANO_VER"
    
    # Link against the local Ncurses we just built
    # We manually pass the include and lib paths
    export CFLAGS="-I$(pwd)/../ncurses-$NCURSES_VER/include -static"
    export LDFLAGS="-L$(pwd)/../ncurses-$NCURSES_VER/lib -static"
    export LIBS="-lncurses -ltinfo" 

    ./configure --enable-tiny --disable-libmagic --disable-mouse \
        --disable-help --disable-browser --disable-speller --disable-justify
        
    make -j$JOBS
    unset CFLAGS LDFLAGS LIBS
    popd
fi
# Install Nano
cp "$DEP_DIR/nano-$NANO_VER/src/nano" rootfs/bin/nano
strip rootfs/bin/nano

# 3. GREP (Search)
GREP_VER="3.11"
if [ ! -f "$DEP_DIR/grep-$GREP_VER/src/grep" ]; then
    echo "Downloading and Compiling Grep..."
    download_and_extract "https://ftp.gnu.org/gnu/grep/grep-$GREP_VER.tar.xz" "grep-$GREP_VER.tar.xz" "grep-$GREP_VER"
    
    pushd "$DEP_DIR/grep-$GREP_VER"
    ./configure --disable-perl-regexp --disable-nls --enable-static LDFLAGS="-static"
    make -j$JOBS
    popd
fi
cp "$DEP_DIR/grep-$GREP_VER/src/grep" rootfs/bin/grep
strip rootfs/bin/grep

# 4. SED (Stream Editor)
SED_VER="4.9"
if [ ! -f "$DEP_DIR/sed-$SED_VER/sed/sed" ]; then
    echo "Downloading and Compiling Sed..."
    download_and_extract "https://ftp.gnu.org/gnu/sed/sed-$SED_VER.tar.xz" "sed-$SED_VER.tar.xz" "sed-$SED_VER"
    
    pushd "$DEP_DIR/sed-$SED_VER"
    ./configure --disable-nls --enable-static LDFLAGS="-static"
    make -j$JOBS
    popd
fi
cp "$DEP_DIR/sed-$SED_VER/sed/sed" rootfs/bin/sed
strip rootfs/bin/sed

# 5. GAWK (Awk)
GAWK_VER="5.3.0"
if [ ! -f "$DEP_DIR/gawk-$GAWK_VER/gawk" ]; then
    echo "Downloading and Compiling Gawk..."
    download_and_extract "https://ftp.gnu.org/gnu/gawk/gawk-$GAWK_VER.tar.xz" "gawk-$GAWK_VER.tar.xz" "gawk-$GAWK_VER"
    
    pushd "$DEP_DIR/gawk-$GAWK_VER"
    ./configure --disable-nls --enable-static --disable-extensions --disable-lint LDFLAGS="-static"
    make -j$JOBS
    popd
fi
cp "$DEP_DIR/gawk-$GAWK_VER/gawk" rootfs/bin/gawk
strip rootfs/bin/gawk
ln -sf gawk rootfs/bin/awk

# 4. TERMINFO (Critical for Nano to work)
# We need to copy the 'linux' terminal definition from the host or the ncurses build
# to the rootfs so nano knows how to clear screen, move cursor, etc.
mkdir -p rootfs/usr/share/terminfo/l
mkdir -p rootfs/usr/share/terminfo/v
mkdir -p rootfs/usr/share/terminfo/x

# Try to find the definition in our local ncurses build first, or fallback to host
if [ -f "$DEP_DIR/ncurses-$NCURSES_VER/misc/terminfo.src" ]; then
    # Compile the linux entry specifically for our OS
    echo "Compiling terminfo..."
    tic -o rootfs/usr/share/terminfo -x -e linux,vt100,xterm "$DEP_DIR/ncurses-$NCURSES_VER/misc/terminfo.src"
else
    # Fallback: Copy from host (might be incompatible if versions differ too much, but usually works)
    cp /usr/share/terminfo/l/linux rootfs/usr/share/terminfo/l/ 2>/dev/null || true
    cp /usr/share/terminfo/v/vt100 rootfs/usr/share/terminfo/v/ 2>/dev/null || true
    cp /usr/share/terminfo/x/xterm rootfs/usr/share/terminfo/x/ 2>/dev/null || true
fi

echo "--- 1.3.5 preparing Keymaps (Binary Format) ---"
KBD_VER="2.6.4"
if [ ! -d "$DEP_DIR/kbd-$KBD_VER" ]; then
    echo "Downloading KBD (for keymap data)..."
    download_and_extract "https://cdn.kernel.org/pub/linux/utils/kbd/kbd-$KBD_VER.tar.xz" "kbd-$KBD_VER.tar.xz" "kbd-$KBD_VER"
fi

echo "Converting Keymaps to .bmap..."
mkdir -p rootfs/usr/share/keymaps

# We use the HOST's loadkeys to convert text maps to binary maps
# This avoids running a complex loadkeys on the target.
# We iterate over common layouts and convert them.

find "$DEP_DIR/kbd-$KBD_VER/data/keymaps" -name "*.map" -o -name "*.map.gz" | while read mapfile; do
    NAME=$(basename "$mapfile" .gz)
    NAME=$(basename "$NAME" .map)
    
    # Convert to binary using host loadkeys (-b flag)
    # We accept failures (some maps might have missing includes)
    loadkeys -b "$mapfile" > rootfs/usr/share/keymaps/$NAME.bmap 2>/dev/null || true
done

echo "Keymap conversion done."

echo "--- 1.4 Compiling GRUB (Bootloader Tools) ---"
GRUB_VER="2.12"
# We need grub-install and the i386-pc modules
if [ ! -f "grub_cache/usr/local/sbin/grub-install" ]; then
    echo "Downloading and Compiling GRUB..."
    download_and_extract "https://ftp.gnu.org/gnu/grub/grub-$GRUB_VER.tar.gz" "grub-$GRUB_VER.tar.gz" "grub-$GRUB_VER"
    
    pushd "$DEP_DIR/grub-$GRUB_VER"
    
    # 1. Clean previous failed builds to avoid stale dependency paths
    if [ -f "Makefile" ]; then 
        echo "Cleaning previous GRUB build..."
        make distclean || true
    fi

    # 2. Configure for i386-pc (BIOS)
    # We explicitly disable features that often cause static linking headaches
    # We must ensure python3 is used for list generation
    echo "Configuring GRUB..."
    PYTHON=python3 ./configure --disable-werror --disable-nls --enable-static --disable-shared \
            --disable-device-mapper --disable-libzfs --disable-liblzma \
            --target=i386 --with-platform=pc \
            LDFLAGS="-static" LIBS="-lz -lbz2 -lpng16 -lbrotlidec -lbrotlicommon -lm" \
            FREETYPE_LIBS="-lfreetype -lpng16 -lz -lbz2 -lbrotlidec -lbrotlicommon -lm"

    # Fix for missing extra_deps.lst in GRUB 2.12 tarball
    if [ ! -f grub-core/extra_deps.lst ]; then
        touch grub-core/extra_deps.lst
    fi

    # 3. Build with parallel jobs
    
    make -j$JOBS
    
    # Install to a temporary dir then copy what we need
    make install DESTDIR=$(pwd)/../../grub_cache
    popd
fi
# Copy binaries from cache
cp -v grub_cache/usr/local/sbin/grub-install rootfs/bin/
cp -v grub_cache/usr/local/sbin/grub-bios-setup rootfs/bin/
cp -v grub_cache/usr/local/bin/grub-mkimage rootfs/bin/
cp -v grub_cache/usr/local/sbin/grub-probe rootfs/bin/
cp -v grub_cache/usr/local/bin/grub-editenv rootfs/bin/
    
# Copy Modules (The most important part for installation)
mkdir -p rootfs/usr/lib/grub/i386-pc
# Only copy if cache exists, and use -n (no clobber) or just overwrite.
# Since we kept rootfs, we might already have them, but cache is authority for binaries.
if [ -d "grub_cache" ]; then
    echo "Copying GRUB modules from cache..."
    # Only copy necessary files for runtime (.mod, .lst, .img, modinfo.sh)
    # We avoid .module files as they are unstripped/intermediate and take 12MB+
    cp -r grub_cache/usr/local/lib/grub/i386-pc/*.mod rootfs/usr/lib/grub/i386-pc/
    cp -r grub_cache/usr/local/lib/grub/i386-pc/*.lst rootfs/usr/lib/grub/i386-pc/
    cp -r grub_cache/usr/local/lib/grub/i386-pc/*.img rootfs/usr/lib/grub/i386-pc/ 2>/dev/null || true
    cp -r grub_cache/usr/local/lib/grub/i386-pc/*.image rootfs/usr/lib/grub/i386-pc/ 2>/dev/null || true
    cp -r grub_cache/usr/local/lib/grub/i386-pc/modinfo.sh rootfs/usr/lib/grub/i386-pc/
    
    # Verify
    if [ ! -f "rootfs/usr/lib/grub/i386-pc/modinfo.sh" ]; then
        echo "ERROR: GRUB modules failed to copy!"
        exit 1
    fi
fi
    
# Copy extra needed files
mkdir -p rootfs/usr/local/share/grub
if [ -d "grub_cache" ]; then
    cp grub_cache/usr/local/share/grub/* rootfs/usr/local/share/grub/ 2>/dev/null || true
fi

echo "--- 1.5 Preparing Kernel for Live System ---"
if [ ! -f "$KERNEL_BZIMAGE" ]; then
    echo "ERROR: Kernel image not found at $KERNEL_BZIMAGE"
    echo "Please build the kernel first: cd $DEP_DIR/$KERNEL_VERSION && make -j\
$(nproc) bzImage"
    exit 1
fi
# Copy kernel to rootfs so the installer can find it to copy to the target disk
cp "$KERNEL_BZIMAGE" rootfs/boot/kernel

# Verify it actually got there and has permissions
if [ ! -f "rootfs/boot/kernel" ]; then
    echo "CRITICAL ERROR: Kernel failed to copy to rootfs/boot/kernel"
    exit 1
fi
chmod 755 rootfs/boot
chmod 644 rootfs/boot/kernel

unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR LD_LIBRARY_PATH

echo "--- 1.6 Generating System Configuration ---"
mkdir -p rootfs/etc
mkdir -p rootfs/etc/default
mkdir -p rootfs/home

# 0. Global Profile (Locale and PATH)
cat > rootfs/etc/profile <<EOF
export PATH=/bin/apps/system:/bin/apps:/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LANGUAGE=en_US.UTF-8
export GCONV_PATH=/usr/lib/gconv
export LOCPATH=/usr/lib/locale
export TERM=linux
export EDITOR=nano
export PAGER=cat
EOF

# 0.1 Locale Configuration Files
echo "LANG=en_US.UTF-8" > rootfs/etc/default/locale
echo "LANG=en_US.UTF-8" > rootfs/etc/locale.conf

# 1. /etc/passwd
cat > rootfs/etc/passwd <<EOF
root:x:0:0:System Administrator:/root:/bin/init
messagebus:x:18:18:D-Bus Message Daemon User:/var/run/dbus:/bin/false
EOF

# 2. /etc/group
cat > rootfs/etc/group <<EOF
root:x:0:
sudo:x:27:root
users:x:100:
messagebus:x:18:
EOF

# 3. /etc/shadow (Hashes for 'root' with salt GEMINI_SALT)
cat > rootfs/etc/shadow <<EOF
root:\$5\$GEMINI_SALT\$4813494d137e1631bba301d5acab6e7bb7aa74ce1185d456565ef51d737677b2:19000:0:99999:7:::
EOF
chmod 600 rootfs/etc/shadow

# 4. /etc/os-release
echo "NAME=\"GeminiOS\"" > rootfs/etc/os-release
echo "ID=geminios" >> rootfs/etc/os-release
echo "VERSION=\"0.0.1\"" >> rootfs/etc/os-release

# 5. Xorg Configuration
mkdir -p rootfs/etc/X11
mkdir -p rootfs/var/lib/xkb
chmod 777 rootfs/var/lib/xkb
# Ensure compiled directory points to writable location
rm -rf rootfs/usr/share/X11/xkb/compiled
ln -sf /var/lib/xkb rootfs/usr/share/X11/xkb/compiled

mkdir -p rootfs/tmp/.X11-unix
chmod 1777 rootfs/tmp/.X11-unix

cat > rootfs/etc/X11/xorg.conf <<EOF
Section "Files"
    ModulePath "/usr/lib/xorg/modules"
    ModulePath "/usr/lib64/xorg/modules"
    XkbDir "/usr/share/X11/xkb"
EndSection

Section "Module"
    Load "fbdevhw"
EndSection

Section "ServerFlags"
    Option "AutoAddDevices" "true"
    Option "AllowEmptyInput" "true"
EndSection

Section "InputClass"
    Identifier "keyboard"
    MatchIsKeyboard "on"
    Option "XkbRules" "evdev"
    Option "XkbModel" "pc105"
    Option "XkbLayout" "us"
EndSection

Section "Device"
    Identifier "Card0"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection

Section "Monitor"
    Identifier "Monitor0"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Card0"
    Monitor "Monitor0"
    DefaultDepth 24
EndSection

Section "ServerLayout"
    Identifier "Layout0"
    Screen "Screen0"
EndSection
EOF

echo "--- 2. Packaging Initramfs ---"

# Install packages into the offline repository
echo "Creating snake.gpkg..."
( printf "GPKG"; cat rootfs/bin/apps/snake ) > rootfs/var/repo/snake.gpkg

# --- Verification Function ---
verify_rootfs_integrity() {
    echo "Verifying rootfs integrity..."
    local MISSING=0
    local CRITICAL_FILES=(
        "rootfs/bin/init"
       "rootfs/bin/bash"
        "rootfs/bin/sh"
        "rootfs/bin/nano"
        "rootfs/bin/apps/system/loadkmap"
        "rootfs/bin/grub-install"
        "rootfs/boot/kernel"
        "rootfs/usr/lib/grub/i386-pc/modinfo.sh"
        "rootfs/usr/lib/grub/i386-pc/normal.mod"
        "rootfs/usr/lib/grub/i386-pc/linux.mod"
        "rootfs/usr/share/terminfo/l/linux"
        "rootfs/usr/share/terminfo/x/xterm"
        "rootfs/etc/passwd"
        "rootfs/etc/group"
        "rootfs/var/repo/snake.gpkg"
        "rootfs/usr/lib/locale/en_US.UTF-8/LC_CTYPE"
        "rootfs/lib64/libcrypt.so.1"
        "rootfs/usr/bin/pkg-config"
        "rootfs/usr/bin/perl"
        "rootfs/usr/bin/python3"
        "rootfs/usr/bin/g-ir-scanner"
        "rootfs/usr/bin/locale"
        "rootfs/usr/lib64/libz.so"
        "rootfs/usr/lib64/libxml2.so"
        "rootfs/usr/lib64/libudev.so"
        "rootfs/usr/bin/Xorg"
        "rootfs/usr/lib64/libX11.so"
        "rootfs/usr/lib/xorg/modules/drivers/fbdev_drv.so"
        "rootfs/usr/lib/xorg/modules/libfbdevhw.so"
        "rootfs/usr/bin/xinit"
        "rootfs/usr/bin/setxkbmap"
        "rootfs/usr/bin/xterm"
        "rootfs/usr/bin/xprop"
        "rootfs/usr/bin/dbus-daemon"
        "rootfs/usr/lib64/libXtst.so"
        "rootfs/usr/lib64/libglib-2.0.so"
        "rootfs/usr/lib64/libgtk-3.so"
        "rootfs/usr/lib64/libatspi.so"
        "rootfs/usr/lib64/libatk-bridge-2.0.so"
        "rootfs/usr/share/mime/magic"
        "rootfs/usr/share/glib-2.0/schemas/gschemas.compiled"
    )

    for file in "${CRITICAL_FILES[@]}"; do
        if [ ! -e "$file" ]; then
            echo "CRITICAL ERROR: Missing file -> $file"
            MISSING=1
        fi
    done

    if [ "$MISSING" -eq 1 ]; then
        echo "Build Aborted: Rootfs is incomplete."
        exit 1
    fi
    echo "Rootfs integrity check PASSED."

    # Verify Python functionality
    echo "Verifying Python..."
    # We run python directly using host kernel but target libraries.
    # This avoids needing 'chroot' (root perms) or 'qemu-user'.
    if ! env PYTHONHOME=$(pwd)/rootfs/usr \
         LD_LIBRARY_PATH=$(pwd)/rootfs/usr/lib64:$(pwd)/rootfs/usr/lib:/usr/lib64:/usr/lib \
         rootfs/usr/bin/python3 -c "import encodings; print('Python Encodings OK')" >/dev/null 2>&1; then
        echo "ERROR: Python failed to initialize encodings!"
        # Try to show the error
        env PYTHONHOME=$(pwd)/rootfs/usr \
            LD_LIBRARY_PATH=$(pwd)/rootfs/usr/lib64:$(pwd)/rootfs/usr/lib:/usr/lib64:/usr/lib \
            rootfs/usr/bin/python3 -c "import encodings" || true
        exit 1
    fi
}

# Run verification
verify_rootfs_integrity

# Ensure permissions are correct for packing
chmod -R 755 rootfs/usr

echo "--- 2.1 Auto-Optimizing Rootfs (Smart Minification) ---"
# This section automatically reduces size to prevent OOM errors during boot extraction.

# 1. Aggressive Strip (Safely)
# We identify ELF binaries and shared objects to strip unneeded symbols.
# We explicitly EXCLUDE kernel modules (.ko) as stripping them can break loading.
echo "  > Stripping binaries and libraries..."
find rootfs -type f -not -name "*.ko" -exec file {} + | grep 'ELF .*LSB' | cut -d: -f1 | while read -r binary; do
    strip --strip-unneeded "$binary" 2>/dev/null || true
done

# 2. Filesystem cleanup (Development & Static files)
echo "  > Removing development artifacts..."
rm -rf rootfs/usr/include
rm -rf rootfs/usr/lib64/*.a
rm -rf rootfs/usr/lib64/*.la
rm -rf rootfs/usr/lib64/pkgconfig
rm -rf rootfs/usr/share/pkgconfig
rm -rf rootfs/usr/lib64/cmake
rm -rf rootfs/usr/share/aclocal
# Remove man pages, docs, and info pages
echo "  > Removing documentation..."
rm -rf rootfs/usr/share/man
rm -rf rootfs/usr/share/doc
rm -rf rootfs/usr/share/info
rm -rf rootfs/usr/share/gtk-doc

# 3. Locale Cleanup (Keep only English)
echo "  > Removing non-English locales..."
# Remove standard locales
find rootfs/usr/share/locale -mindepth 1 -maxdepth 1 -type d -not -name 'en_US' -not -name 'en' -exec rm -rf {} + 2>/dev/null
# Remove X11 locales (keep C and en_US)
if [ -d "rootfs/usr/share/X11/locale" ]; then
    find rootfs/usr/share/X11/locale -mindepth 1 -maxdepth 1 -type d -not -name 'C' -not -name 'en_US.UTF-8' -exec rm -rf {} + 2>/dev/null
fi

# 4. Python Specific Optimization
echo "  > Optimizing Python library..."
PYLIB=$(find rootfs/usr/lib64 -name "python3.*" -type d | head -n 1)
if [ -n "$PYLIB" ] && [ -d "$PYLIB" ]; then
    # Remove Test suites (massive space saver, ~30MB+)
    rm -rf "$PYLIB/test"
    rm -rf "$PYLIB/unittest"
    rm -rf "$PYLIB"/*/test
    rm -rf "$PYLIB"/*/tests
    # Remove config directories (only needed for building extensions)
    rm -rf "$PYLIB"/config-*
    # Remove __pycache__ (re-generated at runtime if needed, saves space in image)
    find "$PYLIB" -name "__pycache__" -type d -exec rm -rf {} +
fi

echo "  > Optimization Complete. Final Rootfs Size:"
du -sh rootfs

echo "Packing rootfs..."

# Pack the filesystem into a CPIO archive
# We separate directories and files to ensure directories are created first.
# This improves reliability of extraction and ensures structure exists before file placement.
cd rootfs
find . -type d | LC_ALL=C sort > ../filelist.txt
find . -not -type d | LC_ALL=C sort >> ../filelist.txt
# Use maximum compression (-9) to reduce RAM usage on boot
cat ../filelist.txt | cpio -o -H newc --owner 0:0 | lz4 -l -T0 > ../isodir/boot/initramfs.cpio.lz4
cd ..
rm filelist.txt

echo "--- 3. Preparing Kernel & Bootloader ---"
# Check if kernel exists
ls -lh isodir/boot/initramfs.cpio.lz4

if [ ! -f "$KERNEL_BZIMAGE" ]; then
    echo "ERROR: Kernel image not found at $KERNEL_BZIMAGE"
    echo "Please build the kernel first: cd $DEP_DIR/$KERNEL_VERSION && make -j\
$(nproc) bzImage"
    exit 1
fi

cp "$KERNEL_BZIMAGE" isodir/boot/kernel

# Generate GRUB config
cat > isodir/boot/grub/grub.cfg << EOF
set timeout=3
set default=0

menuentry "GeminiOS" {
    linux /boot/kernel console=tty0 quiet
    #linux /boot/kernel console=tty0 console=ttyS0
    initrd /boot/initramfs.cpio.lz4
}
EOF

echo "--- 4. Building ISO ---"
grub-mkrescue -o GeminiOS.iso isodir

echo "--- Done! ---"
echo "Run: qemu-system-x86_64 -cdrom GeminiOS.iso -m 2G -serial stdio -smp 2 -vga std -enable-kvm"
echo "Run with a disk: qemu-system-x86_64 -cdrom GeminiOS.iso -m 2G -serial stdio -hda disk.qcow2 -smp 2 -vga std -enable-kvm"
echo "Run with a disk but first boot the ISO: qemu-system-x86_64 -cdrom GeminiOS.iso -m 2G -serial stdio -hda disk.qcow2 -boot d -smp 2 -vga std -enable-kvm"
echo "Remove the -enable-kvm flag if your host does not support it."

# Remove the object files
rm src/*.o

# and remaining tarballs
rm -f external_dependencies/*tar.xz
rm -f external_dependencies/*tar.gz
rm -f external_dependencies/*tgz