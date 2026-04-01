#!/bin/bash
set -e

PKG_VER="1.36.1"
PKG_NAME="busybox"
SRC_URL="https://busybox.net/downloads/busybox-${PKG_VER}.tar.bz2"
ARCHIVE="busybox-${PKG_VER}.tar.bz2"
DIR="busybox-${PKG_VER}"

download_and_extract "$SRC_URL" "$ARCHIVE" "$DIR"

cd "$DEP_DIR/$DIR"
make distclean >/dev/null 2>&1 || true
make allnoconfig

set_kconfig() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" .config; then
        sed -i "s#^${key}=.*#${key}=${value}#" .config
    else
        echo "${key}=${value}" >> .config
    fi
}

disable_kconfig() {
    local key="$1"
    if grep -q "^${key}=" .config; then
        sed -i "s#^${key}=.*#\\# ${key} is not set#" .config
    elif ! grep -q "^# ${key} is not set\$" .config; then
        echo "# ${key} is not set" >> .config
    fi
}

set_kconfig CONFIG_STATIC y
set_kconfig CONFIG_BUSYBOX y
set_kconfig CONFIG_ASH y
set_kconfig CONFIG_SH_IS_ASH y
set_kconfig CONFIG_FEATURE_SH_STANDALONE y
set_kconfig CONFIG_FEATURE_PREFER_APPLETS y
set_kconfig CONFIG_CAT y
set_kconfig CONFIG_CHMOD y
set_kconfig CONFIG_CHOWN y
set_kconfig CONFIG_CP y
set_kconfig CONFIG_ECHO y
set_kconfig CONFIG_ENV y
set_kconfig CONFIG_FALSE y
set_kconfig CONFIG_LN y
set_kconfig CONFIG_LS y
set_kconfig CONFIG_MKDIR y
set_kconfig CONFIG_MOUNT y
set_kconfig CONFIG_MV y
set_kconfig CONFIG_RM y
set_kconfig CONFIG_SLEEP y
set_kconfig CONFIG_TEST y
set_kconfig CONFIG_TOUCH y
set_kconfig CONFIG_TRUE y
set_kconfig CONFIG_UMOUNT y
set_kconfig CONFIG_UNAME y
disable_kconfig CONFIG_SH_IS_NONE
disable_kconfig CONFIG_BASH_IS_NONE

yes "" | make oldconfig >/dev/null
make -j$JOBS \
    ARCH=x86_64 \
    CROSS_COMPILE=x86_64-gemini-linux-gnu- \
    CC="$TARGET_CC" \
    HOSTCC="$BUILD_CC"

install -Dm755 busybox "$ROOTFS/usr/bin/busybox"
ln -sfn busybox "$ROOTFS/usr/bin/ash"

mkdir -p "$ROOTFS/bin"
if ! rootfs_dirs_alias "$ROOTFS/usr/bin" "$ROOTFS/bin"; then
    ln -sfn ../usr/bin/busybox "$ROOTFS/bin/busybox"
    ln -sfn ../usr/bin/ash "$ROOTFS/bin/ash"
fi
