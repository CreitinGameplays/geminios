#!/bin/bash
set -euo pipefail

resolve_debian_deb() {
    local package_name="$1"
    local package_arch="$2"
    python3 "$ROOT_DIR/build_system/fetch_debian_binary.py" \
        --package "$package_name" \
        --arch "$package_arch" \
        --cache-dir "$DEP_DIR/debian-binaries"
}

extract_deb_member_to_stdout() {
    local deb_path="$1"
    local member_name="$2"
    local tar_member="$3"
    case "$member_name" in
        *.xz) ar p "$deb_path" "$member_name" | tar -xJOf - "$tar_member" ;;
        *.gz) ar p "$deb_path" "$member_name" | tar -xzOf - "$tar_member" ;;
        *.zst) ar p "$deb_path" "$member_name" | tar --zstd -xOf - "$tar_member" ;;
        *.tar) ar p "$deb_path" "$member_name" | tar -xOf - "$tar_member" ;;
        *)
            echo "unsupported Debian archive member format: $member_name" >&2
            return 1
            ;;
    esac
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

read_deb_field() {
    local deb_path="$1"
    local field_name="$2"

    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -f "$deb_path" "$field_name"
        return 0
    fi

    local control_member control_data
    control_member="$(ar t "$deb_path" | grep '^control.tar' | head -n1)"
    [ -n "$control_member" ] || {
        echo "failed to locate control payload in $deb_path" >&2
        return 1
    }

    control_data="$(
        extract_deb_member_to_stdout "$deb_path" "$control_member" "./control" 2>/dev/null ||
        extract_deb_member_to_stdout "$deb_path" "$control_member" "control"
    )"

    FIELD_NAME="$field_name" awk '
        BEGIN {
            target = ENVIRON["FIELD_NAME"] ":"
            collecting = 0
            value = ""
        }
        index($0, target) == 1 {
            collecting = 1
            value = substr($0, length(target) + 1)
            sub(/^[[:space:]]+/, "", value)
            next
        }
        collecting && /^[[:space:]]/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            value = value " " line
            next
        }
        collecting {
            print value
            exit
        }
        END {
            if (collecting) print value
        }
    ' <<<"$control_data"
}

resolve_runtime_package_name() {
    local dev_deb="$1"
    local depends runtime_name

    depends="$(read_deb_field "$dev_deb" Depends || true)"
    runtime_name="$(
        printf '%s\n' "$depends" |
            tr ',|' '\n\n' |
            sed -E 's/\[[^]]+\]//g; s/\([^)]*\)//g; s/:[A-Za-z0-9_-]+//g' |
            awk '{print $1}' |
            grep -E '^libapt-pkg([0-9][A-Za-z0-9.+:~_-]*)?$|^libapt-pkg$' |
            head -n1
    )" || true

    if [ -n "$runtime_name" ]; then
        printf '%s\n' "$runtime_name"
    fi
}

resolve_runtime_deb() {
    local preferred_name="${1:-}"
    shift || true

    local candidate result version path
    local seen=" "
    for candidate in "$preferred_name" "libapt-pkg" "libapt-pkg7.0"; do
        [ -n "$candidate" ] || continue
        case "$seen" in
            *" $candidate "*) continue ;;
        esac
        seen="$seen$candidate "

        if result="$(resolve_debian_deb "$candidate" amd64 2>/dev/null)"; then
            IFS=$'\t' read -r version path <<<"$result"
            printf '%s\t%s\t%s\n' "$candidate" "$version" "$path"
            return 0
        fi
    done

    echo "failed to resolve a Debian runtime package for libapt-pkg" >&2
    return 1
}

IFS=$'\t' read -r LIBAPT_DEV_VER LIBAPT_DEV_DEB < <(resolve_debian_deb libapt-pkg-dev amd64)
LIBAPT_RUNTIME_PREFERRED="$(resolve_runtime_package_name "$LIBAPT_DEV_DEB")"
IFS=$'\t' read -r LIBAPT_RUNTIME_NAME LIBAPT_RUNTIME_VER LIBAPT_RUNTIME_DEB < <(
    resolve_runtime_deb "$LIBAPT_RUNTIME_PREFERRED"
)

if [ "$LIBAPT_DEV_VER" != "$LIBAPT_RUNTIME_VER" ]; then
    echo "libapt-pkg package version mismatch: dev=$LIBAPT_DEV_VER runtime=$LIBAPT_RUNTIME_VER ($LIBAPT_RUNTIME_NAME)" >&2
    exit 1
fi

extract_deb_payload "$LIBAPT_RUNTIME_DEB" "$ROOTFS"
extract_deb_payload "$LIBAPT_DEV_DEB" "$ROOTFS"

if ! find "$ROOTFS/usr/lib/x86_64-linux-gnu" -maxdepth 1 -name 'libapt-pkg.so.[0-9]*' | grep -q .; then
    echo "libapt-pkg runtime library was not staged into $ROOTFS" >&2
    exit 1
fi

mkdir -p "$ROOT_DIR/output/port_versions"
printf '%s\n' "$LIBAPT_RUNTIME_VER" > "$ROOT_DIR/output/port_versions/libapt-pkg.txt"
