#!/bin/bash
set -e

REFPOLICY_SNAPSHOT_VER="2.20260312"
REFPOLICY_URL="https://github.com/SELinuxProject/refpolicy/archive/refs/heads/main.tar.gz"
REFPOLICY_ARCHIVE="refpolicy-$REFPOLICY_SNAPSHOT_VER-main.tar.gz"
REFPOLICY_DIR="refpolicy-main"

download_and_extract \
    "$REFPOLICY_URL" \
    "$REFPOLICY_ARCHIVE" \
    "$REFPOLICY_DIR"

cd "$DEP_DIR/$REFPOLICY_DIR"

# Carry the current upstream refpolicy snapshot because Debian testing/sid are
# still behind the newest kernel SELinux class/permission set.
if [ -f VERSION ] && [ "$(cat VERSION)" != "$REFPOLICY_SNAPSHOT_VER" ]; then
    echo "WARNING: Expected refpolicy VERSION $REFPOLICY_SNAPSHOT_VER but found $(cat VERSION)" >&2
fi

POLICY_SYSROOT="${TARGET_SYSROOT:-$ROOTFS}"
LOADER="$POLICY_SYSROOT/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
LIB_PATH="$POLICY_SYSROOT/lib/x86_64-linux-gnu:$POLICY_SYSROOT/usr/lib/x86_64-linux-gnu:$POLICY_SYSROOT/lib64:$POLICY_SYSROOT/usr/lib64"
TOOL_WRAP_DIR="$(mktemp -d)"
STAGE_DIR="$(mktemp -d)"
FILE_CONTEXTS_LOCAL_BACKUP="$(mktemp)"

cleanup() {
    rm -rf "$TOOL_WRAP_DIR" "$STAGE_DIR"
    rm -f "$FILE_CONTEXTS_LOCAL_BACKUP"
}
trap cleanup EXIT

make_rootfs_tool_wrapper() {
    local wrapper_name="$1"
    shift

    local binary_path=""
    local candidate=""
    for candidate in "$@"; do
        if [ -x "$POLICY_SYSROOT/$candidate" ]; then
            binary_path="$POLICY_SYSROOT/$candidate"
            break
        fi
    done

    if [ -z "$binary_path" ]; then
        echo "ERROR: Missing staged tool for $wrapper_name" >&2
        exit 1
    fi

    cat > "$TOOL_WRAP_DIR/$wrapper_name" <<EOF
#!/bin/sh
exec "$LOADER" --library-path "$LIB_PATH" "$binary_path" "\$@"
EOF
    chmod +x "$TOOL_WRAP_DIR/$wrapper_name"
}

make_rootfs_tool_wrapper checkpolicy usr/bin/checkpolicy
make_rootfs_tool_wrapper checkmodule usr/bin/checkmodule
make_rootfs_tool_wrapper secilc usr/bin/secilc
make_rootfs_tool_wrapper setfiles usr/sbin/setfiles sbin/setfiles
make_rootfs_tool_wrapper sefcontext_compile usr/sbin/sefcontext_compile sbin/sefcontext_compile

export PATH="$TOOL_WRAP_DIR:$PATH"

COMMON_MAKE_ARGS=(
    TYPE=standard
    NAME=default
    DISTRO=debian
    MONOLITHIC=y
    SYSTEMD=n
    DIRECT_INITRC=y
    UNK_PERMS=allow
    WERROR=n
    CHECKPOLICY="$TOOL_WRAP_DIR/checkpolicy"
    CHECKMODULE="$TOOL_WRAP_DIR/checkmodule"
    SECILC="$TOOL_WRAP_DIR/secilc"
    SETFILES="$TOOL_WRAP_DIR/setfiles"
    SEFCONTEXT_COMPILE="$TOOL_WRAP_DIR/sefcontext_compile"
)

make clean || true
# Upstream refpolicy expects make conf to generate policy/modules.conf and the
# related booleans/tunables config before a clean monolithic build.
make "${COMMON_MAKE_ARGS[@]}" conf
make "${COMMON_MAKE_ARGS[@]}"

make \
    DESTDIR="$STAGE_DIR" \
    "${COMMON_MAKE_ARGS[@]}" \
    install

LOCAL_CONTEXTS_PATH="$ROOTFS/etc/selinux/default/contexts/files/file_contexts.local"
if [ -f "$LOCAL_CONTEXTS_PATH" ]; then
    cp -a "$LOCAL_CONTEXTS_PATH" "$FILE_CONTEXTS_LOCAL_BACKUP"
else
    : > "$FILE_CONTEXTS_LOCAL_BACKUP"
fi

rm -f \
    "$ROOTFS/etc/selinux/default/policy"/policy.* \
    "$ROOTFS/etc/selinux/default/contexts/files"/file_contexts* 2>/dev/null || true

cp -a "$STAGE_DIR/." "$ROOTFS/"

if [ -s "$FILE_CONTEXTS_LOCAL_BACKUP" ]; then
    cp -a "$FILE_CONTEXTS_LOCAL_BACKUP" "$LOCAL_CONTEXTS_PATH"
fi
