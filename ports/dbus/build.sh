#!/bin/bash
set -e

DBUS_VER="1.14.10"
download_and_extract "https://dbus.freedesktop.org/releases/dbus/dbus-$DBUS_VER.tar.xz" "dbus-$DBUS_VER.tar.xz" "dbus-$DBUS_VER"

cd "$DEP_DIR/dbus-$DBUS_VER"
export LDFLAGS="$LDFLAGS -L$ROOTFS/usr/lib64 -L$ROOTFS/lib64"
./configure --prefix=/usr \
            --libdir=/usr/lib64 \
            --sysconfdir=/etc \
            --localstatedir=/var \
            --disable-static \
            --disable-doxygen-docs \
            --disable-xml-docs \
            --with-console-auth-dir=/run/console/ \
            --with-dbus-user=messagebus \
            --with-system-pid-file=/run/dbus/pid \
            --with-system-socket=/run/dbus/system_bus_socket \
            --host=x86_64-linux-gnu

make -j$JOBS
make install DESTDIR="$ROOTFS"

# FIX: Remove empty Libs.private from .pc file
if [ -f "$ROOTFS/usr/lib64/pkgconfig/dbus-1.pc" ]; then
    sed -i '/^Libs.private: *$/d' "$ROOTFS/usr/lib64/pkgconfig/dbus-1.pc"
fi
