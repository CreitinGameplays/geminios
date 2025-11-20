#!/bin/bash
set -e # Exit immediately if a command fails

# Configuration
ENABLE_DEBUG=true # Set to true to enable detailed debug logs
KERNEL_VERSION="linux-6.6.14" # Change this if you update kernel version
KERNEL_BZIMAGE="$KERNEL_VERSION/arch/x86/boot/bzImage"

echo "--- 0. Preparing Rootfs ---"
# Clean old artifacts and create directory hierarchy FIRST
rm -rf rootfs
rm -f isodir/boot/initramfs.cpio.gz
mkdir -p isodir/boot
mkdir -p isodir/boot/grub
mkdir -p rootfs/{bin,boot,proc,sys,dev,etc,tmp,mnt,var/repo,bin/apps,bin/apps/system}

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
for pkg in ls pwd cat mkdir touch uname free reboot poweroff clear help gtop rm df mount dd fdisk mkfs lsblk copy move chmod echo kill ps ping head tail wc whoami env date; do
    compile_sys_pkg $pkg
done

# Compile Complex Packages (requiring network)
echo "Compiling gpkg..."
g++ $CXXFLAGS -I src -o rootfs/bin/apps/system/gpkg packages/system/gpkg/gpkg.cpp src/network.cpp src/signals.o -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip rootfs/bin/apps/system/gpkg

echo "Compiling greq..."
g++ $CXXFLAGS -I src -o rootfs/bin/apps/system/greq packages/system/greq/greq.cpp src/network.cpp src/signals.o -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip rootfs/bin/apps/system/greq

echo "Compiling User Tools (passwd, adduser...)"
for tool in passwd adduser userdel usermod su sudo chown; do
    echo "  - $tool"
    g++ $CXXFLAGS -I src -o rootfs/bin/apps/system/$tool packages/system/$tool/$tool.cpp src/user_mgmt.o -lssl -lcrypto -lz -lzstd -ldl -lpthread
    strip rootfs/bin/apps/system/$tool
done

echo "Compiling Installer..."
g++ $CXXFLAGS -I src -o rootfs/bin/apps/system/installer packages/system/installer/installer.cpp src/user_mgmt.o -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip rootfs/bin/apps/system/installer

echo "Setting permissions..."
chmod u+s rootfs/bin/apps/system/su rootfs/bin/apps/system/sudo
mkdir -p rootfs/bin/apps
g++ -static -O2 -I src -o rootfs/bin/apps/snake packages/snake/snake.cpp
strip rootfs/bin/apps/snake

echo "--- 1.2 Compiling Bash (Script Support) ---"
BASH_VER="5.2.21"
# Check if we already compiled it to save time
if [ ! -f "bash-$BASH_VER/bash" ]; then
    echo "Downloading and Compiling Bash..."
    if [ ! -d "bash-$BASH_VER" ]; then
        if [ ! -f "bash-$BASH_VER.tar.gz" ]; then
            wget https://ftp.gnu.org/gnu/bash/bash-$BASH_VER.tar.gz
        fi
        tar -xf bash-$BASH_VER.tar.gz
        rm bash-$BASH_VER.tar.gz
    fi
    cd bash-$BASH_VER
    # Configure for static build, minimal features for scripting
    ./configure --enable-static-link --without-bash-malloc --disable-nls \
        --disable-shared --disable-curses LDFLAGS="-static"
    make -j$(nproc)
    cd ..
fi
# Install to rootfs
cp bash-$BASH_VER/bash rootfs/bin/bash
strip rootfs/bin/bash
ln -sf bash rootfs/bin/sh

echo "--- 1.3 Compiling GNU Tools (Nano, Grep, Ncurses) ---"

# 1. NCURSES (Required for Nano)
NCURSES_VER="6.4"
# Check for either standard or wide library to prevent rebuild loops
if [ ! -f "ncurses-$NCURSES_VER/lib/libncurses.a" ] && [ ! -f "ncurses-$NCURSES_VER/lib/libncursesw.a" ]; then
    echo "Downloading and Compiling Ncurses..."
    if [ ! -d "ncurses-$NCURSES_VER" ]; then
        if [ ! -f "ncurses-$NCURSES_VER.tar.gz" ]; then
            wget https://ftp.gnu.org/pub/gnu/ncurses/ncurses-$NCURSES_VER.tar.gz
        fi
        tar -xf ncurses-$NCURSES_VER.tar.gz
        rm ncurses-$NCURSES_VER.tar.gz
    fi
    cd ncurses-$NCURSES_VER
    # Configure for static, minimal, no C++ bindings, standard linux terminal support
    ./configure --disable-shared --enable-static --without-cxx --without-ada \
        --without-progs --without-tests --enable-widec --with-terminfo-dirs="/usr/share/terminfo" \
        --with-default-terminfo-dir="/usr/share/terminfo" --with-term-lib=tinfo
        
    # Create compat symlink so 'libncurses.a' exists for the check and for packages linking -lncurses
    if [ -f "lib/libncursesw.a" ]; then
        ln -sf libncursesw.a lib/libncurses.a
    fi
    make -j$(nproc)
    cd ..
fi

# 2. NANO (Text Editor)
NANO_VER="7.2"
if [ ! -f "nano-$NANO_VER/src/nano" ]; then
    echo "Downloading and Compiling Nano..."
    if [ ! -d "nano-$NANO_VER" ]; then
        if [ ! -f "nano-$NANO_VER.tar.gz" ]; then
            wget https://www.nano-editor.org/dist/v7/nano-$NANO_VER.tar.gz
        fi
        tar -xf nano-$NANO_VER.tar.gz
        rm nano-$NANO_VER.tar.gz
    fi
    cd nano-$NANO_VER
    
    # Link against the local Ncurses we just built
    # We manually pass the include and lib paths
    export CFLAGS="-I$(pwd)/../ncurses-$NCURSES_VER/include -static"
    export LDFLAGS="-L$(pwd)/../ncurses-$NCURSES_VER/lib -static"
    export LIBS="-lncurses -ltinfo" 

    ./configure --enable-tiny --disable-libmagic --disable-mouse \
        --disable-help --disable-browser --disable-speller --disable-justify
        
    make -j$(nproc)
    unset CFLAGS LDFLAGS LIBS
    cd ..
fi
# Install Nano
cp nano-$NANO_VER/src/nano rootfs/bin/nano
strip rootfs/bin/nano

# 3. GREP (Search)
GREP_VER="3.11"
if [ ! -f "grep-$GREP_VER/src/grep" ]; then
    echo "Downloading and Compiling Grep..."
    if [ ! -d "grep-$GREP_VER" ]; then
        if [ ! -f "grep-$GREP_VER.tar.xz" ]; then
            wget https://ftp.gnu.org/gnu/grep/grep-$GREP_VER.tar.xz
        fi
        tar -xf grep-$GREP_VER.tar.xz
        rm grep-$GREP_VER.tar.xz
    fi
    cd grep-$GREP_VER
    ./configure --disable-perl-regexp --disable-nls --enable-static LDFLAGS="-static"
    make -j$(nproc)
    cd ..
fi
cp grep-$GREP_VER/src/grep rootfs/bin/grep
strip rootfs/bin/grep

# 4. SED (Stream Editor)
SED_VER="4.9"
if [ ! -f "sed-$SED_VER/sed/sed" ]; then
    echo "Downloading and Compiling Sed..."
    if [ ! -d "sed-$SED_VER" ]; then
        if [ ! -f "sed-$SED_VER.tar.xz" ]; then wget https://ftp.gnu.org/gnu/sed/sed-$SED_VER.tar.xz; fi
        tar -xf sed-$SED_VER.tar.xz
        rm sed-$SED_VER.tar.xz
    fi
    cd sed-$SED_VER
    ./configure --disable-nls --enable-static LDFLAGS="-static"
    make -j$(nproc)
    cd ..
fi
cp sed-$SED_VER/sed/sed rootfs/bin/sed
strip rootfs/bin/sed

# 5. GAWK (Awk)
GAWK_VER="5.3.0"
if [ ! -f "gawk-$GAWK_VER/gawk" ]; then
    echo "Downloading and Compiling Gawk..."
    if [ ! -d "gawk-$GAWK_VER" ]; then
        if [ ! -f "gawk-$GAWK_VER.tar.xz" ]; then wget https://ftp.gnu.org/gnu/gawk/gawk-$GAWK_VER.tar.xz; fi
        tar -xf gawk-$GAWK_VER.tar.xz
        rm gawk-$GAWK_VER.tar.xz
    fi
    cd gawk-$GAWK_VER
    ./configure --disable-nls --enable-static --disable-extensions --disable-lint LDFLAGS="-static"
    make -j$(nproc)
    cd ..
fi
cp gawk-$GAWK_VER/gawk rootfs/bin/gawk
strip rootfs/bin/gawk
ln -sf gawk rootfs/bin/awk

# 4. TERMINFO (Critical for Nano to work)
# We need to copy the 'linux' terminal definition from the host or the ncurses build
# to the rootfs so nano knows how to clear screen, move cursor, etc.
mkdir -p rootfs/usr/share/terminfo/l
mkdir -p rootfs/usr/share/terminfo/v
mkdir -p rootfs/usr/share/terminfo/x

# Try to find the definition in our local ncurses build first, or fallback to host
if [ -f "ncurses-$NCURSES_VER/misc/terminfo.src" ]; then
    # Compile the linux entry specifically for our OS
    echo "Compiling terminfo..."
    tic -o rootfs/usr/share/terminfo -x -e linux,vt100,xterm ncurses-$NCURSES_VER/misc/terminfo.src
else
    # Fallback: Copy from host (might be incompatible if versions differ too much, but usually works)
    cp /usr/share/terminfo/l/linux rootfs/usr/share/terminfo/l/ 2>/dev/null || true
    cp /usr/share/terminfo/v/vt100 rootfs/usr/share/terminfo/v/ 2>/dev/null || true
    cp /usr/share/terminfo/x/xterm rootfs/usr/share/terminfo/x/ 2>/dev/null || true
fi

echo "--- 1.4 Compiling GRUB (Bootloader Tools) ---"
GRUB_VER="2.12"
# We need grub-install and the i386-pc modules
if [ ! -f "grub_cache/usr/local/sbin/grub-install" ]; then
    echo "Downloading and Compiling GRUB..."
    if [ ! -d "grub-$GRUB_VER" ]; then
        if [ ! -f "grub-$GRUB_VER.tar.gz" ]; then
            wget https://ftp.gnu.org/gnu/grub/grub-$GRUB_VER.tar.gz
        fi
        tar -xf grub-$GRUB_VER.tar.gz
        rm grub-$GRUB_VER.tar.gz
    fi
    
    cd grub-$GRUB_VER
    
    # Clean previous builds if any to ensure correct config
    if [ -f "Makefile" ]; then make distclean; fi

    # Configure for i386-pc (BIOS) platform but tools run on host arch (x86_64)
    # We link tools statically.
    # --disable-werror is needed as GRUB source has some warnings on new GCC
    ./configure --disable-werror --disable-nls --enable-static --disable-shared \
        --disable-device-mapper --disable-libzfs --disable-liblzma \
        --target=i386 --with-platform=pc \
        LDFLAGS="-static"
    
    make -j$(nproc)
    
    # Install to a temporary dir then copy what we need
    make install DESTDIR=$(pwd)/../grub_cache
    cd ..
fi
# Copy binaries from cache
cp grub_cache/usr/local/sbin/grub-install rootfs/bin/
cp grub_cache/usr/local/sbin/grub-bios-setup rootfs/bin/
cp grub_cache/usr/local/bin/grub-mkimage rootfs/bin/
cp grub_cache/usr/local/sbin/grub-probe rootfs/bin/
cp grub_cache/usr/local/bin/grub-editenv rootfs/bin/
    
# Copy Modules (The most important part for installation)
mkdir -p rootfs/usr/lib/grub/i386-pc
cp -r grub_cache/usr/local/lib/grub/i386-pc/* rootfs/usr/lib/grub/i386-pc/
    
# Copy extra needed files
mkdir -p rootfs/usr/local/share/grub
cp grub_cache/usr/local/share/grub/* rootfs/usr/local/share/grub/ 2>/dev/null || true

echo "--- 1.5 Preparing Kernel for Live System ---"
if [ ! -f "$KERNEL_BZIMAGE" ]; then
    echo "ERROR: Kernel image not found at $KERNEL_BZIMAGE"
    echo "Please build the kernel first: cd $KERNEL_VERSION && make -j\$(nproc) bzImage"
    exit 1
fi
# Copy kernel to rootfs so the installer can find it to copy to the target disk
cp "$KERNEL_BZIMAGE" rootfs/boot/kernel

echo "--- 2. Packaging Initramfs ---"

# Install packages into the offline repository
# Create the magic header and prepend it to the binary
# We use a subshell to ensure the file is written atomically and correctly
echo "Creating snake.gpkg..."
( printf "GPKG"; cat rootfs/bin/apps/snake ) > rootfs/var/repo/snake.gpkg

# Pack the filesystem into a CPIO archive
cd rootfs
find . | cpio -o -H newc --owner root:root | gzip > ../isodir/boot/initramfs.cpio.gz
cd ..

echo "--- 3. Preparing Kernel & Bootloader ---"
# Check if kernel exists
if [ ! -f "$KERNEL_BZIMAGE" ]; then
    echo "ERROR: Kernel image not found at $KERNEL_BZIMAGE"
    echo "Please build the kernel first: cd $KERNEL_VERSION && make -j\$(nproc) bzImage"
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
    initrd /boot/initramfs.cpio.gz
}
EOF

echo "--- 4. Building ISO ---"
grub-mkrescue -o GeminiOS.iso isodir

echo "--- Done! ---"
echo "Run: qemu-system-x86_64 -cdrom GeminiOS.iso -m 512M -serial stdio"
echo "Run with a disk: qemu-system-x86_64 -cdrom GeminiOS.iso -m 512M -serial stdio -hda yourdisk.qcow2"
echo "Run with a disk but first boot the ISO: qemu-system-x86_64 -cdrom GeminiOS.iso -m 512M -serial stdio -hda yourdisk.qcow2 -boot d"

# Remove the o files
rm src/*.o
