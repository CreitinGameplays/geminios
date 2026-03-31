#!/bin/bash
set -e

SUDO_VER="1.9.17p1"
SUDO_ARCHIVE="sudo-$SUDO_VER.tar.gz"
SUDO_DIR="sudo-$SUDO_VER"

download_and_extract \
    "https://www.sudo.ws/dist/$SUDO_ARCHIVE" \
    "$SUDO_ARCHIVE" \
    "$SUDO_DIR"

cd "$DEP_DIR/$SUDO_DIR"
make distclean || true

./configure \
    --prefix=/usr \
    --bindir=/usr/bin \
    --sbindir=/usr/sbin \
    --libexecdir=/usr/libexec \
    --sysconfdir=/etc \
    --host=x86_64-linux-gnu \
    --with-pam \
    --with-pam-login \
    --with-selinux \
    --with-rundir=/run/sudo \
    --disable-log-server \
    --disable-log-client

make -j"$JOBS"
make install DESTDIR="$ROOTFS" INSTALL_OWNER=

# GeminiOS historically shipped an in-tree sudo implementation under the app
# path. Remove it so PATH resolution always reaches the real /usr/bin/sudo.
rm -f "$ROOTFS/usr/bin/apps/system/sudo"

mkdir -p "$ROOTFS/etc/pam.d"

cat > "$ROOTFS/etc/pam.d/sudo" <<'EOF'
auth        include       common-auth
account     include       common-account
session     include       common-session-noninteractive
EOF

cat > "$ROOTFS/etc/pam.d/sudo-i" <<'EOF'
auth        include       common-auth
account     include       common-account
session     include       common-session
EOF

if [ -e "$ROOTFS/etc/sudoers" ]; then
    chmod 0640 "$ROOTFS/etc/sudoers"
fi

cat > "$ROOTFS/etc/sudoers" <<'EOF'
root ALL=(ALL:ALL) ALL
%sudo ALL=(ALL:ALL) ALL
EOF

chmod 4755 "$ROOTFS/usr/bin/sudo"
chmod 0440 "$ROOTFS/etc/sudoers"
