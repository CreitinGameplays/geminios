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
normalize_ncurses_runtime_aliases "$ROOTFS"

# Move clear to /bin
mkdir -p "$ROOTFS/bin"
if [ -f "$ROOTFS/usr/bin/clear" ]; then
    move_rootfs_entry_if_distinct "$ROOTFS/usr/bin/clear" "$ROOTFS/bin/clear"
fi

# Backfill linker-name aliases for the wide ncurses libraries when the package
# install did not provide them. The runtime SONAMEs are normalized separately.
for lib in ncurses form panel menu tinfo; do
    # Link libX.a -> libXw.a only when the canonical archive is still absent.
    if [ ! -e "$ROOTFS$LIBDIR/lib${lib}.a" ] && [ -f "$ROOTFS$LIBDIR/lib${lib}w.a" ]; then
        ln -sf "lib${lib}w.a" "$ROOTFS$LIBDIR/lib${lib}.a"
    fi
    # Link pkgconfig metadata only when the non-wide alias is missing.
    if [ ! -e "$ROOTFS$PCDIR/${lib}.pc" ] && [ -f "$ROOTFS$PCDIR/${lib}w.pc" ]; then
        ln -sf "${lib}w.pc" "$ROOTFS$PCDIR/${lib}.pc"
    fi
done
