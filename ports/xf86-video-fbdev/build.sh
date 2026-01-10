#!/bin/bash
set -e
XF86_VIDEO_FBDEV_VER="0.5.0"
download_and_extract "https://www.x.org/archive/individual/driver/xf86-video-fbdev-$XF86_VIDEO_FBDEV_VER.tar.gz" "xf86-video-fbdev-$XF86_VIDEO_FBDEV_VER.tar.gz" "xf86-video-fbdev-$XF86_VIDEO_FBDEV_VER"
cd "$DEP_DIR/xf86-video-fbdev-$XF86_VIDEO_FBDEV_VER"
./configure --prefix=/usr --disable-static --host=x86_64-linux-gnu
make -j$JOBS
make install DESTDIR="$ROOTFS"
