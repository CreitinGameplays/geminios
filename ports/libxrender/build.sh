#!/bin/bash
set -e

LIBXRENDER_VER="0.9.11"
download_and_extract "https://www.x.org/archive/individual/lib/libXrender-$LIBXRENDER_VER.tar.gz" "libXrender-$LIBXRENDER_VER.tar.gz" "libXrender-$LIBXRENDER_VER"

cd "$DEP_DIR/libXrender-$LIBXRENDER_VER"

# Apply patch if not already applied
if ! grep -q "BufAlloc (xGlyphElt \*, elt, SIZEOF(xGlyphElt));" src/Glyph.c; then
    patch -p1 < "$ROOT_DIR/patches/libXrender-0.9.11-glyph.patch"
fi

./configure --prefix=/usr --disable-static
make -j$JOBS
make install DESTDIR="$ROOTFS"
find "$ROOTFS" -name "*.la" -delete
