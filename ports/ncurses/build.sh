#!/bin/bash
set -e

NCURSES_VER="6.4"
download_and_extract "https://ftp.gnu.org/pub/gnu/ncurses/ncurses-$NCURSES_VER.tar.gz" "ncurses-$NCURSES_VER.tar.gz" "ncurses-$NCURSES_VER"

cd "$DEP_DIR/ncurses-$NCURSES_VER"
LIBDIR="/usr/lib/x86_64-linux-gnu"
PCDIR="$LIBDIR/pkgconfig"
if [ -f Makefile ]; then
    make distclean >/dev/null 2>&1 || true
fi
rm -f config.cache config.status
./configure --prefix=/usr --with-shared --without-cxx --without-ada \
    --enable-widec --with-termlib --with-terminfo-dirs="/usr/share/terminfo" \
    --with-default-terminfo-dir="/usr/share/terminfo" --enable-pc-files \
    --with-versioned-syms \
    --without-tests \
    --libdir="$LIBDIR" --with-pkg-config-libdir="$PCDIR" --host=x86_64-linux-gnu

make -j$JOBS
make install DESTDIR="$ROOTFS"

# Move clear to /bin
mkdir -p "$ROOTFS/bin"
if [ -f "$ROOTFS/usr/bin/clear" ]; then
    move_rootfs_entry_if_distinct "$ROOTFS/usr/bin/clear" "$ROOTFS/bin/clear"
fi

# Preserve Debian bootstrap's ncurses/tinfo provider links when they already
# exist. The runtime packages own the SONAME symlinks, so only backfill
# link-time aliases that are still missing after install.
for lib in ncurses form panel menu tinfo; do
    # Link libX.so -> libXw.so only when no canonical linker name exists yet.
    if [ ! -e "$ROOTFS$LIBDIR/lib${lib}.so" ] && [ -f "$ROOTFS$LIBDIR/lib${lib}w.so" ]; then
        ln -sf "lib${lib}w.so" "$ROOTFS$LIBDIR/lib${lib}.so"
    fi
    # Link libX.a -> libXw.a only when the canonical archive is still absent.
    if [ ! -e "$ROOTFS$LIBDIR/lib${lib}.a" ] && [ -f "$ROOTFS$LIBDIR/lib${lib}w.a" ]; then
        ln -sf "lib${lib}w.a" "$ROOTFS$LIBDIR/lib${lib}.a"
    fi
    # Link pkgconfig metadata only when the non-wide alias is missing.
    if [ ! -e "$ROOTFS$PCDIR/${lib}.pc" ] && [ -f "$ROOTFS$PCDIR/${lib}w.pc" ]; then
        ln -sf "${lib}w.pc" "$ROOTFS$PCDIR/${lib}.pc"
    fi
done
