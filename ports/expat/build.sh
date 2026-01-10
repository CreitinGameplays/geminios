#!/bin/bash
set -e

EXPAT_VER="2.6.0"
download_and_extract "https://github.com/libexpat/libexpat/releases/download/R_2_6_0/expat-$EXPAT_VER.tar.xz" "expat-$EXPAT_VER.tar.xz" "expat-$EXPAT_VER"

cd "$DEP_DIR/expat-$EXPAT_VER"
rm -rf build_cmake
mkdir -p build_cmake && cd build_cmake
cmake -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_INSTALL_LIBDIR=lib64 \
      -DCMAKE_BUILD_TYPE=Release \
      -DEXPAT_BUILD_EXAMPLES=OFF \
      -DEXPAT_BUILD_TESTS=OFF \
      -DEXPAT_SHARED_LIBS=ON \
      ..

make -j$JOBS
make install DESTDIR="$ROOTFS"
