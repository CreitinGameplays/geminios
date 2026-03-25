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
need_cmd readelf
need_cmd sed
need_cmd awk
need_cmd sort
need_cmd uniq
need_cmd readlink

have() {
    command -v "$1" >/dev/null 2>&1
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

is_elf() {
    readelf -h "$1" >/dev/null 2>&1
}

elf_interp() {
    readelf -l "$1" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p' | sed 's/^[[:space:]]*//'
}

elf_needed() {
    readelf -d "$1" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p'
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
    for p in "${STANDARD_DIRS[@]}"; do
        search_dirs+=("$p")
    done

    local missing=0
    while IFS= read -r needed; do
        [[ -n "$needed" ]] || continue
        local resolved=""
        if resolved="$(resolve_needed "$needed" "${search_dirs[@]}")"; then
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

check_broken_symlinks
check_multiarch_alias_family "/lib/x86_64-linux-gnu" "/lib64" "/lib64/x86_64-linux-gnu" "system runtime"
check_multiarch_alias_family "/usr/lib/x86_64-linux-gnu" "/usr/lib64" "/usr/lib64/x86_64-linux-gnu" "user runtime"
check_elf_closure
check_ldconfig
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
