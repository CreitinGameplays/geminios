#!/bin/bash
set -euo pipefail

XFSPROGS_VER="6.13.0"
XFSPROGS_BUILD_RUNPATH="$DEP_DIR/xfsprogs-$XFSPROGS_VER/libhandle/.libs:/usr/lib/x86_64-linux-gnu"
XFSPROGS_RUNTIME_RUNPATH="/usr/lib/x86_64-linux-gnu"

strip_xfs_build_runpath() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -aFq "$XFSPROGS_BUILD_RUNPATH" "$file" || return 0

    local pad_len=$(( ${#XFSPROGS_BUILD_RUNPATH} - ${#XFSPROGS_RUNTIME_RUNPATH} ))
    if [ "$pad_len" -lt 0 ]; then
        echo "xfsprogs: replacement RUNPATH is unexpectedly longer for $file" >&2
        return 1
    fi

    FILE="$file" \
    OLD_RUNPATH="$XFSPROGS_BUILD_RUNPATH" \
    NEW_RUNPATH="$XFSPROGS_RUNTIME_RUNPATH" \
    PAD_LEN="$pad_len" \
    perl -0pi -e '
        my $replacement = $ENV{NEW_RUNPATH} . ("\0" x $ENV{PAD_LEN});
        s/\Q$ENV{OLD_RUNPATH}\E/$replacement/g;
    ' "$file"
}

download_and_extract \
    "https://mirrors.edge.kernel.org/pub/linux/utils/fs/xfs/xfsprogs/xfsprogs-$XFSPROGS_VER.tar.xz" \
    "xfsprogs-$XFSPROGS_VER.tar.xz" \
    "xfsprogs-$XFSPROGS_VER"

cd "$DEP_DIR/xfsprogs-$XFSPROGS_VER"
make distclean || true

./configure \
    --prefix=/usr \
    --bindir=/bin \
    --sbindir=/sbin \
    --libdir=/usr/lib/x86_64-linux-gnu \
    --disable-static \
    --enable-libicu=no \
    --with-systemd-unit-dir=no \
    --with-udev-rule-dir=no \
    --with-crond-dir=no \
    --host=x86_64-linux-gnu

make -j"$JOBS"
make install DESTDIR="$ROOTFS"

for binary in \
    "$ROOTFS/usr/sbin/xfs_fsr" \
    "$ROOTFS/usr/sbin/xfs_io" \
    "$ROOTFS/usr/sbin/xfs_scrub" \
    "$ROOTFS/usr/sbin/xfs_spaceman"
do
    strip_xfs_build_runpath "$binary"
done
