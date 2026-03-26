#!/bin/bash
set -e

DBUS_VER="1.14.10"
download_and_extract "https://dbus.freedesktop.org/releases/dbus/dbus-$DBUS_VER.tar.xz" "dbus-$DBUS_VER.tar.xz" "dbus-$DBUS_VER"

cd "$DEP_DIR/dbus-$DBUS_VER"

# Remove any preseeded host DBus runtime from the staging rootfs before
# installing the GeminiOS-owned build, otherwise the builder can end up with
# a dbus-launch/libdbus private-ABI mismatch.
find "$ROOTFS/usr/lib/x86_64-linux-gnu" "$ROOTFS/lib/x86_64-linux-gnu" "$ROOTFS/usr/lib" \
    -maxdepth 1 \
    \( -name 'libdbus-1.so*' -o -name 'libdbus-1.la' \) \
    -exec rm -f {} + 2>/dev/null || true

# Do not force both staged glibc library directories into configure-time
# compiler probes. That can bypass the libc linker script and make autoconf
# fail with GLIBC_PRIVATE symbol errors before the actual build starts.
./configure --prefix=/usr \
            --libdir=/usr/lib/x86_64-linux-gnu \
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

helper="$ROOTFS/usr/libexec/dbus-daemon-launch-helper"
if [ -f "$helper" ]; then
    # A non-root build skips upstream's install-exec-hook, but the final image
    # still needs the helper to be setuid-ready so system bus activation works.
    chmod 4750 "$helper"
    chown 0:18 "$helper" 2>/dev/null || true
fi

# FIX: Remove empty Libs.private from .pc file
if [ -f "$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig/dbus-1.pc" ]; then
    sed -i '/^Libs.private: *$/d' "$ROOTFS/usr/lib/x86_64-linux-gnu/pkgconfig/dbus-1.pc"
fi

# END OF SCRIPT
