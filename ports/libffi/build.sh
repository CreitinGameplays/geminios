#!/bin/bash
set -e

LIBFFI_VER="3.4.4"
download_and_extract "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VER/libffi-$LIBFFI_VER.tar.gz" "libffi-$LIBFFI_VER.tar.gz" "libffi-$LIBFFI_VER"

cd "$DEP_DIR/libffi-$LIBFFI_VER"

# Apply patch if not already applied
if ! grep -q "open_temp_exec_file" src/tramp.c; then
    patch -p1 < "$ROOT_DIR/patches/libffi-3.4.4.patch"
fi

./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"

# libffi records a toolexeclibdir of ${libdir}/../lib and can install the
# shared library under /usr/lib/lib even when libdir is multiarch. Move those
# artifacts back into the canonical Debian libdir and rewrite pkg-config to
# point consumers at the normalized location.
if [ -d "$ROOTFS/usr/lib/lib" ]; then
    mkdir -p "$ROOTFS/usr/lib/x86_64-linux-gnu"
    for artifact in "$ROOTFS/usr/lib/lib"/libffi.so* "$ROOTFS/usr/lib/lib"/libffi.la "$ROOTFS/usr/lib/lib"/libffi.a; do
        [ -e "$artifact" ] || continue
        mv "$artifact" "$ROOTFS/usr/lib/x86_64-linux-gnu/"
    done
    rmdir "$ROOTFS/usr/lib/lib" 2>/dev/null || true
fi

LIBFFI_PC="$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig/libffi.pc"
if [ -f "$LIBFFI_PC" ]; then
    sed -i 's|^toolexeclibdir=.*|toolexeclibdir=${libdir}|' "$LIBFFI_PC"
    sed -i 's|^Libs: -L${toolexeclibdir} |Libs: -L${libdir} |' "$LIBFFI_PC"
fi
