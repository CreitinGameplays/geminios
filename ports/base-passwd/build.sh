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

entry_exists() {
    local file_path="$1"
    local entry_name="$2"
    [ -f "$file_path" ] || return 1
    awk -F: -v key="$entry_name" '$1 == key { found = 1; exit } END { exit !found }' "$file_path"
}

append_line_if_missing() {
    local file_path="$1"
    local entry_name="$2"
    local line="$3"
    if entry_exists "$file_path" "$entry_name"; then
        return 0
    fi
    printf '%s\n' "$line" >> "$file_path"
}

merge_master_accounts_into_rootfs() {
    local passwd_file="$ROOTFS/etc/passwd"
    local group_file="$ROOTFS/etc/group"
    local shadow_file="$ROOTFS/etc/shadow"
    local passwd_master="$ROOTFS/usr/share/base-passwd/passwd.master"
    local group_master="$ROOTFS/usr/share/base-passwd/group.master"

    mkdir -p "$ROOTFS/etc"
    touch "$passwd_file" "$group_file" "$shadow_file"

    if [ -f "$group_master" ]; then
        while IFS=: read -r group_name _ gid members; do
            [ -n "$group_name" ] || continue
            append_line_if_missing "$group_file" "$group_name" "$group_name:x:$gid:$members"
        done < "$group_master"
    fi

    if [ -f "$passwd_master" ]; then
        while IFS=: read -r user_name _ uid gid gecos home shell; do
            [ -n "$user_name" ] || continue
            append_line_if_missing "$passwd_file" "$user_name" \
                "$user_name:x:$uid:$gid:$gecos:$home:$shell"
            if [ "$user_name" != "root" ]; then
                append_line_if_missing "$shadow_file" "$user_name" \
                    "$user_name:!:19000:0:99999:7:::"
            fi
        done < "$passwd_master"
    fi

    chmod 600 "$shadow_file"
}

IFS=$'\t' read -r BASE_PASSWD_VER BASE_PASSWD_DEB < <(resolve_debian_deb base-passwd amd64)
IFS=$'\t' read -r _ LIBDEBCONFCLIENT_DEB < <(resolve_debian_deb libdebconfclient0 amd64)

mkdir -p "$ROOT_DIR/output/port_versions"
printf '%s\n' "$BASE_PASSWD_VER" > "$ROOT_DIR/output/port_versions/base-passwd.txt"

extract_deb_payload "$BASE_PASSWD_DEB" "$ROOTFS"
extract_deb_payload "$LIBDEBCONFCLIENT_DEB" "$ROOTFS"
merge_master_accounts_into_rootfs
