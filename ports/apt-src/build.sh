#!/bin/bash
set -euo pipefail

resolve_archive_deb() {
    local package_name="$1"
    local package_arch="$2"
    python3 "$ROOT_DIR/build_system/fetch_debian_binary.py" \
        --package "$package_name" \
        --arch "$package_arch" \
        --cache-dir "$DEP_DIR/archive-binaries"
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
            echo "unsupported archive data payload format: $data_member" >&2
            return 1
            ;;
    esac
}

stage_bootstrap_archive_index() {
    local cache_dir="${GEMINIOS_BOOTSTRAP_CACHE_DIR:-$ROOT_DIR/external_dependencies/devuan-bootstrap}"
    local repo_dir="$ROOTFS/var/repo/devuan"
    mkdir -p "$repo_dir"

    if [ -f "$cache_dir/Packages" ]; then
        cp -f "$cache_dir/Packages" "$repo_dir/Packages"
    fi
    if [ -f "$cache_dir/Packages.gz" ]; then
        cp -f "$cache_dir/Packages.gz" "$repo_dir/Packages.gz"
    fi
}

load_archive_backend_config() {
    ARCHIVE_PACKAGES_URL="http://deb.devuan.org/merged/dists/freia/main/binary-amd64/Packages.gz"
    ARCHIVE_BASE_URL="http://deb.devuan.org/merged"
    ARCHIVE_APT_ARCH="amd64"

    local config_path="$ROOT_DIR/build_system/gpkg_debian.conf"
    [ -f "$config_path" ] || return 0

    local raw_line line key value
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line="$(printf '%s' "$raw_line" | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$line" ] || continue
        case "$line" in
            *=*)
                key="${line%%=*}"
                value="${line#*=}"
                value="${value%\"}"
                value="${value#\"}"
                case "$key" in
                    PACKAGES_URL) [ -n "$value" ] && ARCHIVE_PACKAGES_URL="$value" ;;
                    BASE_URL) [ -n "$value" ] && ARCHIVE_BASE_URL="$value" ;;
                    APT_ARCH) [ -n "$value" ] && ARCHIVE_APT_ARCH="$value" ;;
                esac
                ;;
        esac
    done < "$config_path"
}

derive_apt_source_line() {
    local suite="freia"
    local component="main"
    local parsed
    parsed="$(printf '%s\n' "$ARCHIVE_PACKAGES_URL" | sed -En 's#^.*/dists/([^/]+)/([^/]+)/binary-[^/]+/Packages(.gz)?$#\1 \2#p' | head -n1)"
    if [ -n "$parsed" ]; then
        read -r suite component <<<"$parsed"
    fi

    local source_base_url="${ARCHIVE_BASE_URL%/}"
    local source_options=""
    if [ -f "$ROOTFS/usr/share/keyrings/devuan-archive-keyring.gpg" ]; then
        source_options=' [signed-by=/usr/share/keyrings/devuan-archive-keyring.gpg]'
    elif [ -f "$ROOTFS/usr/share/keyrings/devuan-keyring.gpg" ]; then
        source_options=' [signed-by=/usr/share/keyrings/devuan-keyring.gpg]'
    elif [ -f "$ROOTFS/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
        source_options=' [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg]'
    fi

    printf 'deb%s %s %s %s\n' "$source_options" "$source_base_url" "$suite" "$component"
}

seed_apt_runtime_config() {
    load_archive_backend_config

    mkdir -p \
        "$ROOTFS/etc/apt/apt.conf.d" \
        "$ROOTFS/etc/apt/sources.list.d" \
        "$ROOTFS/var/lib/apt/lists/partial" \
        "$ROOTFS/var/cache/apt/archives/partial" \
        "$ROOTFS/var/lib/dpkg"

    [ -f "$ROOTFS/var/lib/dpkg/status" ] || : > "$ROOTFS/var/lib/dpkg/status"
    rm -f "$ROOTFS/etc/apt/apt.conf.d/99geminios-debian.conf"
    rm -f "$ROOTFS/etc/apt/apt.conf.d/99geminios-local-repo.conf"

    derive_apt_source_line > "$ROOTFS/etc/apt/sources.list"

    cat > "$ROOTFS/etc/apt/apt.conf.d/99geminios-devuan.conf" <<EOF
Acquire::Languages "none";
Acquire::PDiffs "false";
Acquire::AllowReleaseInfoChange::Suite "true";
Acquire::AllowReleaseInfoChange::Codename "true";
APT::Architecture "${ARCHIVE_APT_ARCH}";
EOF
}

IFS=$'\t' read -r APT_VER APT_DEB < <(resolve_archive_deb apt amd64)
IFS=$'\t' read -r _ APT_UTILS_DEB < <(resolve_archive_deb apt-utils amd64)
IFS=$'\t' read -r _ LIBSECCOMP_DEB < <(resolve_archive_deb libseccomp2 amd64)
IFS=$'\t' read -r _ GPGV_DEB < <(resolve_archive_deb gpgv amd64)
IFS=$'\t' read -r _ LIBGCRYPT_DEB < <(resolve_archive_deb libgcrypt20 amd64)
IFS=$'\t' read -r _ LIBGPG_ERROR_DEB < <(resolve_archive_deb libgpg-error0 amd64)
IFS=$'\t' read -r _ ARCHIVE_KEYRING_DEB < <(resolve_archive_deb devuan-keyring all)

mkdir -p "$ROOT_DIR/output/port_versions"
printf '%s\n' "$APT_VER" > "$ROOT_DIR/output/port_versions/apt-src.txt"

extract_deb_payload "$APT_DEB" "$ROOTFS"
extract_deb_payload "$APT_UTILS_DEB" "$ROOTFS"
extract_deb_payload "$LIBSECCOMP_DEB" "$ROOTFS"
extract_deb_payload "$GPGV_DEB" "$ROOTFS"
extract_deb_payload "$LIBGCRYPT_DEB" "$ROOTFS"
extract_deb_payload "$LIBGPG_ERROR_DEB" "$ROOTFS"
extract_deb_payload "$ARCHIVE_KEYRING_DEB" "$ROOTFS"

if [ -f "$ROOTFS/usr/share/keyrings/devuan-keyring.gpg" ] && [ ! -e "$ROOTFS/usr/share/keyrings/devuan-archive-keyring.gpg" ]; then
    ln -s devuan-keyring.gpg "$ROOTFS/usr/share/keyrings/devuan-archive-keyring.gpg"
fi

stage_bootstrap_archive_index
seed_apt_runtime_config
