#!/bin/bash
set -e

NCURSES_VER="6.4"
download_and_extract "https://ftp.gnu.org/pub/gnu/ncurses/ncurses-$NCURSES_VER.tar.gz" "ncurses-$NCURSES_VER.tar.gz" "ncurses-$NCURSES_VER"

cd "$DEP_DIR/ncurses-$NCURSES_VER"
./configure --prefix=/usr --with-shared --without-cxx --without-ada \
    --enable-widec --with-termlib --with-terminfo-dirs="/usr/share/terminfo" \
    --with-default-terminfo-dir="/usr/share/terminfo" --enable-pc-files --with-pkg-config-libdir=/usr/lib/pkgconfig --host=x86_64-linux-gnu

make -j$JOBS
make install DESTDIR="$ROOTFS"

# Move clear to /bin
mkdir -p "$ROOTFS/bin"
if [ -f "$ROOTFS/usr/bin/clear" ]; then
    mv "$ROOTFS/usr/bin/clear" "$ROOTFS/bin/clear"
fi

# Create compat symlinks
for lib in ncurses form panel menu tinfo; do
    # Link libX.so -> libXw.so
    if [ -f "$ROOTFS/usr/lib/lib${lib}w.so" ]; then
        ln -sf "lib${lib}w.so" "$ROOTFS/usr/lib/lib${lib}.so"
    fi
    # Link libX.so.6 -> libXw.so.6
    if [ -f "$ROOTFS/usr/lib/lib${lib}w.so.6" ]; then
        ln -sf "lib${lib}w.so.6" "$ROOTFS/usr/lib/lib${lib}.so.6"
    fi
    # Link libX.a -> libXw.a
    if [ -f "$ROOTFS/usr/lib/lib${lib}w.a" ]; then
        ln -sf "lib${lib}w.a" "$ROOTFS/usr/lib/lib${lib}.a"
    fi
    # Link pkgconfig
    if [ -f "$ROOTFS/usr/lib/pkgconfig/${lib}w.pc" ]; then
        ln -sf "${lib}w.pc" "$ROOTFS/usr/lib/pkgconfig/${lib}.pc"
    fi
done

