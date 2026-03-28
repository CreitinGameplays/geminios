#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-/}"
ROOT="${ROOT%/}"
[[ -z "$ROOT" ]] && ROOT="/"

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="/tmp/geminios-lib-audit-$STAMP"
LOG="$REPORT_DIR/report.txt"
mkdir -p "$REPORT_DIR"

exec > >(tee "$LOG") 2>&1

FAILS=0
WARNS=0
CHECKS=0

say()  { printf '%s\n' "$*"; }
ok()   { CHECKS=$((CHECKS + 1)); printf '[OK] %s\n' "$*"; }
warn() { WARNS=$((WARNS + 1)); printf '[WARN] %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf '[FAIL] %s\n' "$*"; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

need_cmd bash
need_cmd find
need_cmd grep
need_cmd readelf
need_cmd sed
need_cmd awk
need_cmd sort
need_cmd uniq
need_cmd readlink

have() {
    command -v "$1" >/dev/null 2>&1
}

trim_whitespace() {
    local s="${1-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s\n' "$s"
}

root_path() {
    local p="${1:-/}"
    if [[ "$ROOT" == "/" ]]; then
        printf '%s\n' "$p"
    else
        printf '%s%s\n' "$ROOT" "$p"
    fi
}

canon() {
    readlink -f "$1" 2>/dev/null || printf '%s\n' "$1"
}

display_path() {
    local p="${1:-}"
    if [[ "$ROOT" == "/" ]]; then
        printf '%s\n' "$p"
    else
        printf '%s\n' "${p#$ROOT}"
    fi
}

is_elf() {
    readelf -h "$1" >/dev/null 2>&1
}

elf_interp() {
    readelf -l "$1" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p' | sed 's/^[[:space:]]*//'
}

elf_needed() {
    readelf -d "$1" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p'
}

elf_soname() {
    readelf -d "$1" 2>/dev/null | sed -n 's/.*Library soname: \[\(.*\)\].*/\1/p'
}

elf_runpath() {
    readelf -d "$1" 2>/dev/null | sed -n 's/.*Library \(runpath\|rpath\): \[\(.*\)\].*/\2/p'
}

expand_origin_list() {
    local raw="$1"
    local origin="$2"
    raw="${raw//\$\{ORIGIN\}/$origin}"
    raw="${raw//\$ORIGIN/$origin}"
    printf '%s\n' "$raw"
}

join_by_colon() {
    local IFS=':'
    printf '%s\n' "$*"
}

say "GeminiOS Library Audit"
say "Root: $ROOT"
say "Report: $REPORT_DIR"
say

STANDARD_DIRS=(
    "$(root_path /lib)"
    "$(root_path /lib64)"
    "$(root_path /lib/x86_64-linux-gnu)"
    "$(root_path /lib64/x86_64-linux-gnu)"
    "$(root_path /usr/lib)"
    "$(root_path /usr/lib64)"
    "$(root_path /usr/lib/x86_64-linux-gnu)"
    "$(root_path /usr/lib64/x86_64-linux-gnu)"
    "$(root_path /usr/local/lib)"
    "$(root_path /usr/local/lib64)"
)

declare -A LOADER_CONF_SEEN=()
declare -A LOADER_DIR_SEEN=()
declare -A LIVE_LDD_CACHE=()
LOADER_CONFIG_DIRS=()

RUNTIME_PATHS=(
    "$(root_path /lib)"
    "$(root_path /lib64)"
    "$(root_path /lib/x86_64-linux-gnu)"
    "$(root_path /lib64/x86_64-linux-gnu)"
    "$(root_path /usr/lib)"
    "$(root_path /usr/lib64)"
    "$(root_path /usr/lib/x86_64-linux-gnu)"
    "$(root_path /usr/lib64/x86_64-linux-gnu)"
    "$(root_path /usr/local/lib)"
    "$(root_path /usr/local/lib64)"
    "$(root_path /bin)"
    "$(root_path /sbin)"
    "$(root_path /usr/bin)"
    "$(root_path /usr/sbin)"
    "$(root_path /usr/libexec)"
    "$(root_path /bin/apps/system)"
)

add_loader_config_dir() {
    local dir="${1-}"
    [[ -n "$dir" ]] || return 0
    [[ -d "$dir" || -L "$dir" ]] || return 0
    [[ -n "${LOADER_DIR_SEEN[$dir]:-}" ]] && return 0
    LOADER_DIR_SEEN["$dir"]=1
    LOADER_CONFIG_DIRS+=("$dir")
    return 0
}

parse_ld_so_conf_file() {
    local file="${1-}"
    [[ -n "$file" ]] || return 0
    [[ -e "$file" || -L "$file" ]] || return 0

    local key
    key="$(canon "$file")"
    [[ -n "${LOADER_CONF_SEEN[$key]:-}" ]] && return 0
    LOADER_CONF_SEEN["$key"]=1

    local line pattern actual_pattern match dir
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(trim_whitespace "$line")"
        [[ -n "$line" ]] || continue

        if [[ "$line" =~ ^include[[:space:]]+(.+)$ ]]; then
            pattern="$(trim_whitespace "${BASH_REMATCH[1]}")"
            if [[ "$pattern" == /* ]]; then
                actual_pattern="$(root_path "$pattern")"
            else
                actual_pattern="$(dirname "$file")/$pattern"
            fi
            for match in $actual_pattern; do
                [[ -e "$match" || -L "$match" ]] || continue
                parse_ld_so_conf_file "$match"
            done
            continue
        fi

        [[ "$line" =~ ^hwcap([[:space:]]|$) ]] && continue

        if [[ "$line" == /* ]]; then
            dir="$(root_path "$line")"
        else
            dir="$(dirname "$file")/$line"
        fi
        add_loader_config_dir "$dir"
    done < "$file"
}

load_loader_config_dirs() {
    parse_ld_so_conf_file "$(root_path /etc/ld.so.conf)"
}

live_ldd_output() {
    local file="${1-}"
    [[ "$ROOT" == "/" ]] || return 1
    have ldd || return 1

    if [[ -z "${LIVE_LDD_CACHE[$file]+x}" ]]; then
        LIVE_LDD_CACHE["$file"]="$(ldd "$file" 2>&1 || true)"
    fi
    printf '%s\n' "${LIVE_LDD_CACHE[$file]}"
}

live_ldd_resolves_needed() {
    local file="${1-}"
    local needed="${2-}"
    [[ -n "$file" && -n "$needed" ]] || return 1

    local out line
    out="$(live_ldd_output "$file")" || return 1
    line="$(grep -F "$needed" <<<"$out" | head -n 1 || true)"
    [[ -n "$line" ]] || return 1
    grep -Eq '=>[[:space:]]*not found|not found' <<<"$line" && return 1
    return 0
}

load_loader_config_dirs

check_broken_symlinks() {
    say "== Broken symlink scan =="
    local roots=()
    local d
    for d in \
        "$(root_path /lib)" \
        "$(root_path /lib64)" \
        "$(root_path /usr/lib)" \
        "$(root_path /usr/lib64)" \
        "$(root_path /bin)" \
        "$(root_path /sbin)" \
        "$(root_path /usr/bin)" \
        "$(root_path /usr/sbin)" \
        "$(root_path /usr/libexec)" \
        "$(root_path /bin/apps/system)"; do
        [[ -e "$d" || -L "$d" ]] && roots+=("$d")
    done

    local out="$REPORT_DIR/broken-symlinks.txt"
    : > "$out"

    if ((${#roots[@]})); then
        while IFS= read -r -d '' p; do
            printf '%s\n' "$p" >> "$out"
        done < <(find "${roots[@]}" -xtype l -print0 2>/dev/null || true)
    fi

    if [[ -s "$out" ]]; then
        fail "Found broken symlinks. See $out"
    else
        ok "No broken symlinks found in core runtime paths"
    fi
    say
}

check_pending_runtime_fixups() {
    say "== Pending runtime fixup audit =="

    local trigger_dir
    trigger_dir="$(root_path /var/lib/gpkg/triggers)"
    local pending="$REPORT_DIR/pending-runtime-fixups.txt"
    : > "$pending"

    if [[ -s "$trigger_dir/selinux-relabel.list" ]]; then
        printf '%s\n' "$(display_path "$trigger_dir/selinux-relabel.list")" >> "$pending"
    fi

    if [[ -e "$(root_path /.autorelabel)" ]]; then
        warn "SELinux autorelabel is pending ($(display_path "$(root_path /.autorelabel)"))"
    fi

    if [[ -s "$pending" ]]; then
        fail "Pending gpkg runtime fixups detected. See $pending"
    else
        ok "No pending gpkg runtime fixup queues detected"
    fi
    say
}

check_leftover_runtime_package_artifacts() {
    say "== Leftover runtime package artifact scan =="

    local out="$REPORT_DIR/runtime-package-artifacts.txt"
    : > "$out"
    local roots=()
    local d
    for d in "${RUNTIME_PATHS[@]}"; do
        [[ -e "$d" || -L "$d" ]] && roots+=("$d")
    done

    if ((${#roots[@]})); then
        while IFS= read -r -d '' p; do
            printf '%s\n' "$(display_path "$p")" >> "$out"
        done < <(find "${roots[@]}" \
            \( -name '*.gpkg-new' -o -name '*.gpkg-tmp' -o -name '*.dpkg-new' -o -name '*.dpkg-tmp' \) \
            -print0 2>/dev/null || true)
    fi

    if [[ -s "$out" ]]; then
        fail "Found leftover package-manager runtime artifacts. See $out"
    else
        ok "No leftover package-manager runtime artifacts found in runtime paths"
    fi
    say
}

check_multiarch_alias_family() {
    local canonical="$1"
    local compat="$2"
    local legacy="$3"
    local label="$4"

    say "== Multiarch alias audit: $label =="

    local cdir="$(root_path "$canonical")"
    local xdir="$(root_path "$compat")"
    local ldir="$(root_path "$legacy")"

    if [[ ! -e "$cdir" && ! -e "$xdir" && ! -e "$ldir" ]]; then
        warn "Skipped $label; none of its directories exist"
        say
        return
    fi

    declare -A seen=()
    local dir name p rp

    for dir in "$cdir" "$xdir" "$ldir"; do
        [[ -d "$dir" || -L "$dir" ]] || continue
        while IFS= read -r -d '' p; do
            name="$(basename "$p")"
            seen["$name"]=1
        done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null || true)
    done

    local family_fail=0
    for name in "${!seen[@]}"; do
        local a="$cdir/$name"
        local b="$xdir/$name"
        local c="$ldir/$name"
        local refs=()
        [[ -e "$a" || -L "$a" ]] && refs+=("$(canon "$a")")
        [[ -e "$b" || -L "$b" ]] && refs+=("$(canon "$b")")
        [[ -e "$c" || -L "$c" ]] && refs+=("$(canon "$c")")
        [[ ${#refs[@]} -le 1 ]] && continue
        rp="$(printf '%s\n' "${refs[@]}" | sort -u | wc -l)"
        if [[ "$rp" != "1" ]]; then
            family_fail=1
            printf '%s\n' "$canonical/$name" >> "$REPORT_DIR/multiarch-alias-mismatches.txt"
            printf '  %s -> %s\n' "$a" "$(canon "$a")" >> "$REPORT_DIR/multiarch-alias-mismatches.txt" 2>/dev/null || true
            printf '  %s -> %s\n' "$b" "$(canon "$b")" >> "$REPORT_DIR/multiarch-alias-mismatches.txt" 2>/dev/null || true
            printf '  %s -> %s\n' "$c" "$(canon "$c")" >> "$REPORT_DIR/multiarch-alias-mismatches.txt" 2>/dev/null || true
        fi
    done

    if [[ "$family_fail" == "1" ]]; then
        fail "Multiarch aliases diverge in $label. See $REPORT_DIR/multiarch-alias-mismatches.txt"
    else
        ok "Multiarch aliases look consistent for $label"
    fi
    say
}

runtime_alias_candidate_dirs_for_file() {
    local path="$1"
    case "$path" in
        "$(root_path /lib/x86_64-linux-gnu)"/*|"$(root_path /lib64)"/*|"$(root_path /lib64/x86_64-linux-gnu)"/*)
            printf '%s\n' \
                "$(root_path /lib/x86_64-linux-gnu)" \
                "$(root_path /lib64)" \
                "$(root_path /lib64/x86_64-linux-gnu)"
            ;;
        "$(root_path /usr/lib/x86_64-linux-gnu)"/*|"$(root_path /usr/lib64)"/*|"$(root_path /usr/lib64/x86_64-linux-gnu)"/*)
            printf '%s\n' \
                "$(root_path /usr/lib/x86_64-linux-gnu)" \
                "$(root_path /usr/lib64)" \
                "$(root_path /usr/lib64/x86_64-linux-gnu)"
            ;;
        *)
            dirname "$path"
            ;;
    esac | awk '!seen[$0]++'
}

check_soname_links() {
    say "== SONAME/linker alias audit =="

    local roots=()
    local d
    for d in \
        "$(root_path /lib)" \
        "$(root_path /lib64)" \
        "$(root_path /lib/x86_64-linux-gnu)" \
        "$(root_path /lib64/x86_64-linux-gnu)" \
        "$(root_path /usr/lib)" \
        "$(root_path /usr/lib64)" \
        "$(root_path /usr/lib/x86_64-linux-gnu)" \
        "$(root_path /usr/lib64/x86_64-linux-gnu)" \
        "$(root_path /usr/local/lib)" \
        "$(root_path /usr/local/lib64)"; do
        [[ -e "$d" || -L "$d" ]] && roots+=("$d")
    done

    local out="$REPORT_DIR/soname-link-issues.txt"
    : > "$out"
    local count=0
    declare -A seen=()

    if ((${#roots[@]})); then
        while IFS= read -r -d '' f; do
            is_elf "$f" || continue
            local soname base real alias_path key
            soname="$(elf_soname "$f")"
            [[ -n "$soname" ]] || continue
            base="$(basename "$f")"
            [[ "$base" == "$soname" ]] && continue

            real="$(canon "$f")"
            key="$real|$soname"
            [[ -n "${seen[$key]:-}" ]] && continue
            seen["$key"]=1
            count=$((count + 1))

            alias_path="$(dirname "$f")/$soname"
            if [[ ! -e "$alias_path" && ! -L "$alias_path" ]]; then
                {
                    printf '%s\n' "$(display_path "$f")"
                    printf '  soname: %s\n' "$soname"
                    printf '  real: %s\n' "$(display_path "$real")"
                    printf '  issue: missing SONAME entry in %s\n' "$(display_path "$(dirname "$f")")"
                    printf '\n'
                } >> "$out"
                continue
            fi

            if [[ "$alias_path" -ef "$f" ]]; then
                continue
            fi

            if [[ ! "$alias_path" -ef "$real" ]]; then
                {
                    printf '%s\n' "$(display_path "$f")"
                    printf '  soname: %s\n' "$soname"
                    printf '  real: %s\n' "$(display_path "$real")"
                    printf '  alias: %s\n' "$(display_path "$alias_path")"
                    printf '  issue: SONAME entry does not resolve to the same file\n'
                    printf '\n'
                } >> "$out"
                continue
            fi

            if [[ ! -L "$alias_path" ]]; then
                {
                    printf '%s\n' "$(display_path "$f")"
                    printf '  soname: %s\n' "$soname"
                    printf '  real: %s\n' "$(display_path "$real")"
                    printf '  alias: %s\n' "$(display_path "$alias_path")"
                    printf '  issue: SONAME entry exists but is not a symlink\n'
                    printf '\n'
                } >> "$out"
            fi
        done < <(find "${roots[@]}" -maxdepth 1 -type f \
            \( -name '*.so.[0-9]*' -o -name 'ld-linux*.so*' \) \
            -print0 2>/dev/null || true)
    fi

    if [[ -s "$out" ]]; then
        fail "SONAME/linker alias audit found broken library aliasing. See $out"
    else
        ok "SONAME/linker alias audit passed for $count versioned shared object(s)"
    fi
    say
}

resolve_needed() {
    local needed="$1"
    shift
    local d
    for d in "$@"; do
        [[ -n "$d" ]] || continue
        if [[ -e "$d/$needed" ]]; then
            printf '%s\n' "$d/$needed"
            return 0
        fi
    done
    return 1
}

audit_one_elf() {
    local f="$1"
    local short="${f#$ROOT}"
    [[ -z "$short" || "$short" == "$f" ]] && short="$f"

    local interp runpath origin
    origin="$(dirname "$f")"
    interp="$(elf_interp "$f")"
    runpath="$(elf_runpath "$f")"

    if [[ -n "$interp" ]]; then
        if [[ ! -e "$(root_path "$interp")" ]]; then
            fail "$short: missing interpreter $interp"
        fi
    fi

    if [[ -n "$runpath" ]]; then
        if grep -Eq '(^|:)(/home/|/tmp/|/build|/rootfs|/build_sysroot|/workspace)' <<<"$runpath"; then
            fail "$short: suspicious host/build path in RUNPATH/RPATH: $runpath"
        fi
    fi

    local search_dirs=()
    if [[ -n "$runpath" ]]; then
        local expanded
        expanded="$(expand_origin_list "$runpath" "$origin")"
        while IFS=':' read -r -a parts; do
            local p
            for p in "${parts[@]}"; do
                [[ -n "$p" ]] && search_dirs+=("$p")
            done
        done <<<"$expanded"
    fi

    local p
    for p in "${LOADER_CONFIG_DIRS[@]}"; do
        search_dirs+=("$p")
    done

    for p in "${STANDARD_DIRS[@]}"; do
        search_dirs+=("$p")
    done

    local missing=0
    while IFS= read -r needed; do
        [[ -n "$needed" ]] || continue
        local resolved=""
        if resolved="$(resolve_needed "$needed" "${search_dirs[@]}")"; then
            :
        elif live_ldd_resolves_needed "$f" "$needed"; then
            :
        else
            missing=1
            printf '%s : missing %s\n' "$short" "$needed" >> "$REPORT_DIR/missing-needed.txt"
        fi
    done < <(elf_needed "$f")

    if [[ "$missing" == "1" ]]; then
        fail "$short: missing shared libraries"
    fi
}

check_elf_closure() {
    say "== ELF dependency audit =="

    local roots=()
    local d
    for d in \
        "$(root_path /bin)" \
        "$(root_path /sbin)" \
        "$(root_path /usr/bin)" \
        "$(root_path /usr/sbin)" \
        "$(root_path /usr/lib)" \
        "$(root_path /usr/lib64)" \
        "$(root_path /lib)" \
        "$(root_path /lib64)" \
        "$(root_path /usr/libexec)" \
        "$(root_path /bin/apps/system)"; do
        [[ -e "$d" || -L "$d" ]] && roots+=("$d")
    done

    : > "$REPORT_DIR/missing-needed.txt"

    local count=0
    if ((${#roots[@]})); then
        while IFS= read -r -d '' f; do
            if is_elf "$f"; then
                count=$((count + 1))
                audit_one_elf "$f"
            fi
        done < <(find "${roots[@]}" \( -type f -o -type l \) -print0 2>/dev/null || true)
    fi

    if [[ -s "$REPORT_DIR/missing-needed.txt" ]]; then
        fail "ELF dependency audit found unresolved libraries. See $REPORT_DIR/missing-needed.txt"
    else
        ok "ELF dependency audit passed for $count objects"
    fi
    say
}

check_ldconfig() {
    say "== ldconfig sanity check =="
    local out="$REPORT_DIR/ldconfig.txt"
    local actionable="$REPORT_DIR/ldconfig-actionable.txt"
    local benign_re="Path \`.*' given more than once|Can't stat /usr/local/lib(64)?(/x86_64-linux-gnu)?: No such file or directory|is the dynamic linker, ignoring"
    if have ldconfig; then
        if [[ "$ROOT" == "/" ]]; then
            ldconfig -v -N -X >"$out" 2>&1 || true
        else
            ldconfig -r "$ROOT" -v -N -X >"$out" 2>&1 || true
        fi

        grep -Ev "$benign_re" "$out" >"$actionable" || true

        if grep -Eq "not found|No such file|cannot open shared object file|is not a symbolic link|Can't stat " "$actionable"; then
            warn "ldconfig reported actionable warnings. See $actionable"
        else
            ok "ldconfig did not report actionable linker-cache/library issues"
        fi
    else
        warn "ldconfig not available; skipped"
    fi
    say
}

check_live_ldd_bindings() {
    say "== Live loader/binding audit =="

    if [[ "$ROOT" != "/" ]]; then
        warn "Skipping live ldd binding audit for non-live root $ROOT"
        say
        return
    fi

    have ldd || {
        warn "ldd not available; skipped"
        say
        return
    }

    local targets=(
        "/bin/bash"
        "/usr/bin/gpkg"
        "/usr/bin/apt-sortpkgs"
        "/usr/bin/apt-ftparchive"
        "/bin/apps/system/gpkg-worker"
        "/usr/bin/python3"
        "/usr/bin/perl"
        "/usr/bin/nano"
        "/usr/sbin/ldconfig"
        "/usr/lib/apt/solvers/solver3"
        "/usr/lib/apt/solvers/apt"
        "/usr/lib/apt/planners/apt"
        "/usr/lib/x86_64-linux-gnu/libc.so.6"
        "/usr/lib/x86_64-linux-gnu/libstdc++.so.6"
        "/usr/lib/x86_64-linux-gnu/libglib-2.0.so.0"
    )

    local out="$REPORT_DIR/live-ldd-bindings.txt"
    local failures="$REPORT_DIR/live-ldd-bindings-failures.txt"
    : > "$out"
    : > "$failures"

    local target full rc checked=0
    for target in "${targets[@]}"; do
        full="$(root_path "$target")"
        [[ -e "$full" || -L "$full" ]] || continue
        is_elf "$full" || continue
        checked=$((checked + 1))

        local target_out="$REPORT_DIR/ldd-$(sed 's#[^A-Za-z0-9._-]#_#g' <<<"$target").txt"
        printf '### %s\n' "$target" >> "$out"
        set +e
        ldd -r "$full" > "$target_out" 2>&1
        rc=$?
        set -e
        cat "$target_out" >> "$out"
        printf '\n' >> "$out"

        if [[ "$rc" -ne 0 ]] || grep -Eq 'not found|undefined symbol' "$target_out"; then
            printf '%s\n' "$target" >> "$failures"
        fi
    done

    if [[ -s "$failures" ]]; then
        fail "Live loader/binding audit found unresolved runtime issues. See $out and $failures"
    else
        ok "Live loader/binding audit passed for $checked critical object(s)"
    fi
    say
}

run_smoke_tests() {
    say "== Runtime smoke tests =="

    if [[ "$ROOT" != "/" ]]; then
        warn "Skipping command smoke tests for non-live root $ROOT"
        say
        return
    fi

    local tests=(
        "bash --version"
        "sh -c true"
        "pkill --help"
        "ldconfig -p"
        "gpkg --help"
        "nano --version"
        "python3 --version"
        "perl -e 'print qq(ok\\n)'"
    )

    local t safe out rc
    : > "$REPORT_DIR/smoke-tests.txt"

    for t in "${tests[@]}"; do
        local cmd="${t%% *}"
        have "$cmd" || continue
        safe="$(sed 's#[^A-Za-z0-9._-]#_#g' <<<"$cmd")"
        out="$REPORT_DIR/smoke-$safe.txt"

        set +e
        bash -lc "$t" >"$out" 2>&1
        rc=$?
        set -e

        printf '### %s (rc=%s)\n' "$t" "$rc" >> "$REPORT_DIR/smoke-tests.txt"
        cat "$out" >> "$REPORT_DIR/smoke-tests.txt"
        printf '\n' >> "$REPORT_DIR/smoke-tests.txt"

        if grep -q 'no version information available' "$out"; then
            fail "$t emitted a symbol-version warning"
            continue
        fi

        if [[ "$rc" -ne 0 ]]; then
            warn "$t exited with status $rc"
        else
            ok "$t"
        fi
    done
    say
}

run_gpkg_verify() {
    say "== gpkg package verification =="

    local worker=""
    if have gpkg-worker; then
        worker="gpkg-worker"
    elif [[ -x "$(root_path /bin/apps/system/gpkg-worker)" ]]; then
        worker="$(root_path /bin/apps/system/gpkg-worker)"
    fi

    local info_dir="$(root_path /var/lib/gpkg/info)"
    if [[ -z "$worker" || ! -d "$info_dir" ]]; then
        warn "gpkg-worker or gpkg info directory not available; skipped"
        say
        return
    fi

    local count=0
    local failed=0
    local skipped=0
    : > "$REPORT_DIR/gpkg-verify-skipped.txt"
    : > "$REPORT_DIR/gpkg-verify-failures.txt"
    while IFS= read -r -d '' list; do
        local pkg
        pkg="$(basename "$list" .list)"
        if [[ "$pkg" == *.system-backup ]]; then
            skipped=$((skipped + 1))
            printf '%s\n' "$pkg" >> "$REPORT_DIR/gpkg-verify-skipped.txt"
            continue
        fi
        count=$((count + 1))
        if [[ "$ROOT" == "/" ]]; then
            if "$worker" --verify "$pkg" >/dev/null 2>&1; then
                :
            else
                failed=$((failed + 1))
                printf '%s\n' "$pkg" >> "$REPORT_DIR/gpkg-verify-failures.txt"
            fi
        else
            if "$worker" --root "$ROOT" --verify "$pkg" >/dev/null 2>&1; then
                :
            else
                failed=$((failed + 1))
                printf '%s\n' "$pkg" >> "$REPORT_DIR/gpkg-verify-failures.txt"
            fi
        fi
    done < <(find "$info_dir" -maxdepth 1 -name '*.list' -print0 2>/dev/null | sort -z)

    if [[ "$count" -eq 0 ]]; then
        warn "No gpkg package manifests found"
    elif [[ "$failed" -eq 0 ]]; then
        if [[ "$skipped" -gt 0 ]]; then
            ok "gpkg verification passed for $count package(s); skipped $skipped backup manifest(s)"
        else
            ok "gpkg verification passed for $count package(s)"
        fi
    else
        fail "gpkg verification failed for $failed/$count package(s). See $REPORT_DIR/gpkg-verify-failures.txt"
    fi
    say
}

dump_versions() {
    say "== Core library versions =="
    local libs=(
        "/usr/lib/x86_64-linux-gnu/libc.so.6"
        "/usr/lib/x86_64-linux-gnu/libgcc_s.so.1"
        "/usr/lib/x86_64-linux-gnu/libstdc++.so.6"
        "/usr/lib/x86_64-linux-gnu/libtinfo.so.6"
        "/usr/lib/x86_64-linux-gnu/libncursesw.so.6"
        "/usr/lib/x86_64-linux-gnu/libssl.so.3"
        "/usr/lib/x86_64-linux-gnu/libcrypto.so.3"
    )
    local p
    for p in "${libs[@]}"; do
        local full
        full="$(root_path "$p")"
        if [[ -e "$full" ]]; then
            printf '%s -> %s\n' "$p" "$(canon "$full")"
        fi
    done
    ok "Captured core library resolutions"
    say
}

check_pending_runtime_fixups
check_broken_symlinks
check_leftover_runtime_package_artifacts
check_multiarch_alias_family "/lib/x86_64-linux-gnu" "/lib64" "/lib64/x86_64-linux-gnu" "system runtime"
check_multiarch_alias_family "/usr/lib/x86_64-linux-gnu" "/usr/lib64" "/usr/lib64/x86_64-linux-gnu" "user runtime"
check_soname_links
check_elf_closure
check_ldconfig
check_live_ldd_bindings
run_smoke_tests
run_gpkg_verify
dump_versions

say "== Summary =="
say "Checks: $CHECKS"
say "Warnings: $WARNS"
say "Failures: $FAILS"
say "Full log: $LOG"

if [[ "$FAILS" -ne 0 ]]; then
    exit 1
fi
