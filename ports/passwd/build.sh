#!/bin/bash
set -e

resolve_debian_deb() {
    local package_name="$1"
    local package_arch="$2"
    python3 "$ROOT_DIR/build_system/fetch_debian_binary.py" \
        --package "$package_name" \
        --arch "$package_arch" \
        --cache-dir "$DEP_DIR/debian-binaries"
}

extract_deb_payload() {
    local deb_path="$1"
    local dest_dir="$2"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$deb_path" "$dest_dir"
        return 0
    fi

    local data_member
    data_member="$(ar t "$deb_path" | grep '^data.tar' | head -n1)"
    [ -n "$data_member" ] || {
        echo "failed to locate data payload in $deb_path" >&2
        return 1
    }

    case "$data_member" in
        *.xz) ar p "$deb_path" "$data_member" | tar -xJf - -C "$dest_dir" ;;
        *.gz) ar p "$deb_path" "$data_member" | tar -xzf - -C "$dest_dir" ;;
        *.zst) ar p "$deb_path" "$data_member" | tar --zstd -xf - -C "$dest_dir" ;;
        *.tar) ar p "$deb_path" "$data_member" | tar -xf - -C "$dest_dir" ;;
        *)
            echo "unsupported Debian data payload format: $data_member" >&2
            return 1
            ;;
    esac
}

IFS=$'\t' read -r PASSWD_VER PASSWD_DEB < <(resolve_debian_deb passwd amd64)
IFS=$'\t' read -r _ LOGIN_DEFS_DEB < <(resolve_debian_deb login.defs all)
IFS=$'\t' read -r _ LIBBSD_DEB < <(resolve_debian_deb libbsd0 amd64)
IFS=$'\t' read -r _ LIBMD_DEB < <(resolve_debian_deb libmd0 amd64)

mkdir -p "$ROOT_DIR/output/port_versions"
printf '%s\n' "$PASSWD_VER" > "$ROOT_DIR/output/port_versions/passwd.txt"

extract_deb_payload "$PASSWD_DEB" "$ROOTFS"
extract_deb_payload "$LOGIN_DEFS_DEB" "$ROOTFS"
extract_deb_payload "$LIBBSD_DEB" "$ROOTFS"
extract_deb_payload "$LIBMD_DEB" "$ROOTFS"

# Remove the GeminiOS-specific account-management frontends so the real
# Debian shadow tools own the standard entry points.
rm -f "$ROOTFS/bin/apps/system/passwd" \
      "$ROOTFS/bin/apps/system/useradd" \
      "$ROOTFS/bin/apps/system/userdel" \
      "$ROOTFS/bin/apps/system/usermod"
