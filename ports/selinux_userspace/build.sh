#!/bin/bash
set -e

SELINUX_USERSPACE_VER="3.10"
SELINUX_USERSPACE_URL="https://github.com/SELinuxProject/selinux/archive/refs/tags/$SELINUX_USERSPACE_VER.tar.gz"
SELINUX_USERSPACE_ARCHIVE="selinux-$SELINUX_USERSPACE_VER.tar.gz"
SELINUX_USERSPACE_DIR="selinux-$SELINUX_USERSPACE_VER"

download_and_extract \
    "$SELINUX_USERSPACE_URL" \
    "$SELINUX_USERSPACE_ARCHIVE" \
    "$SELINUX_USERSPACE_DIR"

cd "$DEP_DIR/$SELINUX_USERSPACE_DIR"

SELINUX_SRC_ROOT="$DEP_DIR/$SELINUX_USERSPACE_DIR"
LIBSEPOL_SRC_DIR="$SELINUX_SRC_ROOT/libsepol/src"
COMMON_MAKE_ARGS=(
    "PREFIX=/usr"
    "LIBDIR=/usr/lib/x86_64-linux-gnu"
    "SHLIBDIR=/usr/lib/x86_64-linux-gnu"
)

# Build the upstream subprojects explicitly. Passing SUBDIRS=... to the
# top-level Makefile leaks that value into nested makes and breaks libselinux.
run_selinux_make() {
    local subdir="$1"
    shift
    make -C "$SELINUX_SRC_ROOT/$subdir" "${COMMON_MAKE_ARGS[@]}" "$@"
}

run_selinux_make libsepol clean || true
run_selinux_make libsepol -j"$JOBS"
run_selinux_make libsepol DESTDIR="$ROOTFS" install

run_selinux_make libselinux clean || true
run_selinux_make libselinux -j"$JOBS" LDFLAGS="$LDFLAGS -L$LIBSEPOL_SRC_DIR"
run_selinux_make libselinux DESTDIR="$ROOTFS" LDFLAGS="$LDFLAGS -L$LIBSEPOL_SRC_DIR" install

run_selinux_make libsemanage clean || true
run_selinux_make libsemanage -j"$JOBS" LDFLAGS="$LDFLAGS -L$LIBSEPOL_SRC_DIR"
run_selinux_make libsemanage DESTDIR="$ROOTFS" LDFLAGS="$LDFLAGS -L$LIBSEPOL_SRC_DIR" install

run_selinux_make checkpolicy clean || true
run_selinux_make checkpolicy -j"$JOBS" LIBSEPOLA="$LIBSEPOL_SRC_DIR/libsepol.a" checkpolicy checkmodule
install -Dm755 "$SELINUX_SRC_ROOT/checkpolicy/checkpolicy" "$ROOTFS/usr/bin/checkpolicy"
install -Dm755 "$SELINUX_SRC_ROOT/checkpolicy/checkmodule" "$ROOTFS/usr/bin/checkmodule"
install -Dm644 "$SELINUX_SRC_ROOT/checkpolicy/checkpolicy.8" "$ROOTFS/usr/share/man/man8/checkpolicy.8"
install -Dm644 "$SELINUX_SRC_ROOT/checkpolicy/checkmodule.8" "$ROOTFS/usr/share/man/man8/checkmodule.8"

run_selinux_make secilc clean || true
run_selinux_make secilc -j"$JOBS" CHECKPOLICY=true LDFLAGS="$LDFLAGS -L$LIBSEPOL_SRC_DIR" secilc secil2conf secil2tree
install -Dm755 "$SELINUX_SRC_ROOT/secilc/secilc" "$ROOTFS/usr/bin/secilc"
install -Dm755 "$SELINUX_SRC_ROOT/secilc/secil2conf" "$ROOTFS/usr/bin/secil2conf"
install -Dm755 "$SELINUX_SRC_ROOT/secilc/secil2tree" "$ROOTFS/usr/bin/secil2tree"
