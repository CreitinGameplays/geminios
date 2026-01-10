#!/bin/bash
set -e
STARTUP_NOTIFICATION_VER="0.12"
download_and_extract "https://www.freedesktop.org/software/startup-notification/releases/startup-notification-$STARTUP_NOTIFICATION_VER.tar.gz" "startup-notification-$STARTUP_NOTIFICATION_VER.tar.gz" "startup-notification-$STARTUP_NOTIFICATION_VER"
cd "$DEP_DIR/startup-notification-$STARTUP_NOTIFICATION_VER"
./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc --localstatedir=/var --disable-static
make -j$JOBS
make DESTDIR="$ROOTFS" install
