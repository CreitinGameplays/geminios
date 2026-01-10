#!/bin/bash
set -e
GRUB_VER="2.12"
download_and_extract "https://ftp.gnu.org/gnu/grub/grub-$GRUB_VER.tar.gz" "grub-$GRUB_VER.tar.gz" "grub-$GRUB_VER"
cd "$DEP_DIR/grub-$GRUB_VER"
if [ -f "Makefile" ]; then make distclean || true; fi

# Unset these as GRUB's internal build system for modules is very sensitive 
# to PIC/PIE and other flags that might be set in the environment.
# It will use its own flags for the target (i386-pc).
unset CFLAGS
unset CXXFLAGS
unset LDFLAGS

PYTHON=python3 ./configure --prefix=/usr --disable-werror --disable-nls --enable-static --disable-shared \
        --disable-device-mapper --disable-libzfs --disable-liblzma \
        --target=i386 --with-platform=pc \
        LDFLAGS="-static" LIBS="-lz -lbz2 -lpng16 -lbrotlidec -lbrotlicommon -lm" \
        FREETYPE_LIBS="-lfreetype -lpng16 -lz -lbz2 -lbrotlidec -lbrotlicommon -lm" --host=x86_64-linux-gnu
if [ ! -f grub-core/extra_deps.lst ]; then touch grub-core/extra_deps.lst; fi
make -j$JOBS
make install DESTDIR="$ROOTFS"
