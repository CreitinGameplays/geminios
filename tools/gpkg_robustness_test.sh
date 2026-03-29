#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: gpkg_robustness_test.sh [options]

Aggressive, automated robustness test for GeminiOS gpkg.

Warning:
  This script performs real package-manager mutations:
  - installs and removes test packages
  - purges conffiles for test packages
  - runs gpkg clean
  - optionally adds a repository
  - optionally runs a full gpkg upgrade

Best used on a disposable VM / ISO / test machine.

Options:
  -h, --help              Show this help text
  --keep-changes          Do not remove test packages or repo files on exit
  --with-upgrade          Also run a full 'gpkg upgrade -y'
  --verify-touched-only   Verify only touched packages, not every registered package
  --repo URL              Also test a positive 'gpkg add-repo URL' path
  --packages "A B C"      Space-separated candidate test packages
  --protected "A B C"     Space-separated packages to probe for removal protection
  --gpkg PATH             gpkg binary to use
  --gpkg-worker PATH      gpkg-worker binary to use
  --state-root PATH       Root used for filesystem assertions, default /

Environment overrides:
  GPKG_BIN
  GPKG_WORKER_BIN
  GPKG_STATE_ROOT
  GPKG_TEST_KEEP_CHANGES=0|1
  GPKG_TEST_FULL_UPGRADE=0|1
  GPKG_TEST_VERIFY_ALL=0|1
  GPKG_TEST_REPO_URL=https://...
  GPKG_TEST_TRANSACTION_CANDIDATES="nano file tree jq htop bc less patch"
  GPKG_TEST_PROTECTED_CANDIDATES="libc6 libc-bin ca-certificates"
  GPKG_ALLOW_NON_ROOT=0|1

Examples:
  sudo ./tools/gpkg_robustness_test.sh
  sudo ./tools/gpkg_robustness_test.sh --repo https://example.invalid/x86_64
  sudo GPKG_TEST_TRANSACTION_CANDIDATES="nano file jq" ./tools/gpkg_robustness_test.sh
EOF
}

ROOT="${GPKG_STATE_ROOT:-/}"
KEEP_CHANGES="${GPKG_TEST_KEEP_CHANGES:-0}"
FULL_UPGRADE="${GPKG_TEST_FULL_UPGRADE:-0}"
VERIFY_ALL="${GPKG_TEST_VERIFY_ALL:-1}"
POSITIVE_REPO_URL="${GPKG_TEST_REPO_URL:-}"
TRANSACTION_CANDIDATES="${GPKG_TEST_TRANSACTION_CANDIDATES:-file tree jq less patch bc nano htop}"
PROTECTED_CANDIDATES="${GPKG_TEST_PROTECTED_CANDIDATES:-ca-certificates libc-bin libc6}"
GPKG_BIN="${GPKG_BIN:-}"
GPKG_WORKER_BIN="${GPKG_WORKER_BIN:-}"
ALLOW_NON_ROOT="${GPKG_ALLOW_NON_ROOT:-0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --keep-changes)
            KEEP_CHANGES=1
            ;;
        --with-upgrade)
            FULL_UPGRADE=1
            ;;
        --verify-touched-only)
            VERIFY_ALL=0
            ;;
        --repo)
            [[ $# -ge 2 ]] || { echo "Missing value for --repo" >&2; exit 1; }
            POSITIVE_REPO_URL="$2"
            shift
            ;;
        --packages)
            [[ $# -ge 2 ]] || { echo "Missing value for --packages" >&2; exit 1; }
            TRANSACTION_CANDIDATES="$2"
            shift
            ;;
        --protected)
            [[ $# -ge 2 ]] || { echo "Missing value for --protected" >&2; exit 1; }
            PROTECTED_CANDIDATES="$2"
            shift
            ;;
        --gpkg)
            [[ $# -ge 2 ]] || { echo "Missing value for --gpkg" >&2; exit 1; }
            GPKG_BIN="$2"
            shift
            ;;
        --gpkg-worker)
            [[ $# -ge 2 ]] || { echo "Missing value for --gpkg-worker" >&2; exit 1; }
            GPKG_WORKER_BIN="$2"
            shift
            ;;
        --state-root)
            [[ $# -ge 2 ]] || { echo "Missing value for --state-root" >&2; exit 1; }
            ROOT="$2"
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

ROOT="${ROOT%/}"
[[ -z "$ROOT" ]] && ROOT="/"

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="${GPKG_REPORT_DIR:-/tmp/gpkg-robustness-$STAMP}"
LOG="$REPORT_DIR/report.txt"
mkdir -p "$REPORT_DIR"
exec > >(tee "$LOG") 2>&1

FAILS=0
WARNS=0
SKIPS=0
CHECKS=0
STEP=0
LAST_LOG=""
LAST_RC=0
PRIMARY_PKG=""
SECONDARY_PKG=""
PACKAGE_QUERY=""
PROTECTED_PKG=""
SUMMARY_PRINTED=0
CLEANUP_DONE=0

declare -A ORIGINAL_STATE=()
declare -A ORIGINAL_VERSION=()
declare -A TRACKED_PACKAGES=()
declare -a ADDED_REPO_FILES=()
declare -a TOUCHED_PACKAGES=()

say()  { printf '%s\n' "$*"; }
ok()   { CHECKS=$((CHECKS + 1)); printf '[OK] %s\n' "$*"; }
warn() { WARNS=$((WARNS + 1)); printf '[WARN] %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf '[FAIL] %s\n' "$*"; }
skip() { SKIPS=$((SKIPS + 1)); printf '[SKIP] %s\n' "$*"; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

have() {
    command -v "$1" >/dev/null 2>&1
}

pick_runtime_elf_source() {
    local candidate
    for candidate in \
        /lib/x86_64-linux-gnu/libzstd.so.1 \
        /lib/x86_64-linux-gnu/libc.so.6 \
        /usr/lib/x86_64-linux-gnu/libzstd.so.1 \
        /usr/lib/x86_64-linux-gnu/libc.so.6 \
        "$GPKG_WORKER_BIN"; do
        [[ -r "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

resolve_binary() {
    local current="$1"
    shift
    if [[ -n "$current" ]]; then
        [[ -x "$current" ]] && { printf '%s\n' "$current"; return 0; }
        if command -v "$current" >/dev/null 2>&1; then
            command -v "$current"
            return 0
        fi
        return 1
    fi

    local candidate
    for candidate in "$@"; do
        [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    return 1
}

sanitize_name() {
    sed 's#[^A-Za-z0-9._-]#_#g' <<<"$1"
}

root_path() {
    local p="${1:-/}"
    if [[ "$ROOT" == "/" ]]; then
        printf '%s\n' "$p"
    else
        printf '%s%s\n' "$ROOT" "$p"
    fi
}

INFO_DIR="$(root_path /var/lib/gpkg/info)"
REPO_CACHE_DIR="$(root_path /var/repo)"
SOURCES_DIR="$(root_path /etc/gpkg/sources.list.d)"
PACKAGES_JSON="$(root_path /var/repo/Packages.json)"
BASE_SYSTEM_JSON="$(root_path /usr/share/gpkg/base-system.json)"
SELINUX_CONFIG="$(root_path /etc/selinux/config)"
LIVE_MARKER="$(root_path /etc/geminios-live)"

need_cmd bash
need_cmd find
need_cmd grep
need_cmd sed
need_cmd awk
need_cmd sort
need_cmd xargs

GPKG_BIN="$(resolve_binary "$GPKG_BIN" gpkg /bin/apps/system/gpkg /home/creitin/Documents/geminios/gpkg/bin/gpkg)" || {
    echo "Unable to locate gpkg binary" >&2
    exit 1
}
GPKG_WORKER_BIN="$(resolve_binary "$GPKG_WORKER_BIN" gpkg-worker /bin/apps/system/gpkg-worker /home/creitin/Documents/geminios/gpkg/bin/gpkg-worker)" || {
    echo "Unable to locate gpkg-worker binary" >&2
    exit 1
}

CPU_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
[[ "$CPU_JOBS" =~ ^[0-9]+$ ]] || CPU_JOBS=1
(( CPU_JOBS >= 1 )) || CPU_JOBS=1

run_logged() {
    local label="$1"
    shift
    STEP=$((STEP + 1))
    local safe
    safe="$(sanitize_name "$label")"
    LAST_LOG="$REPORT_DIR/$(printf '%03d' "$STEP")-$safe.log"
    {
        printf '$'
        local arg
        for arg in "$@"; do
            printf ' %q' "$arg"
        done
        printf '\n'
    } >"$LAST_LOG"

    set +e
    "$@" >>"$LAST_LOG" 2>&1
    LAST_RC=$?
    set -e
    return 0
}

expect_success() {
    local label="$1"
    shift
    run_logged "$label" "$@"
    if [[ "$LAST_RC" -eq 0 ]]; then
        ok "$label"
        return 0
    fi
    fail "$label failed (rc=$LAST_RC). See $LAST_LOG"
    return 1
}

expect_failure() {
    local label="$1"
    shift
    run_logged "$label" "$@"
    if [[ "$LAST_RC" -ne 0 ]]; then
        ok "$label rejected invalid usage as expected"
        return 0
    fi
    fail "$label unexpectedly succeeded. See $LAST_LOG"
    return 1
}

assert_last_log_contains() {
    local pattern="$1"
    local message="$2"
    if sed -E $'s/\x1B\\[[0-9;]*m//g' "$LAST_LOG" | grep -Eq -- "$pattern"; then
        ok "$message"
        return 0
    fi
    fail "$message (pattern not found in $LAST_LOG)"
    return 1
}

assert_last_log_not_contains() {
    local pattern="$1"
    local message="$2"
    if sed -E $'s/\x1B\\[[0-9;]*m//g' "$LAST_LOG" | grep -Eq -- "$pattern"; then
        fail "$message (unexpected pattern found in $LAST_LOG)"
        return 1
    fi
    ok "$message"
    return 0
}

assert_last_log_first_package_is() {
    local expected="$1"
    local message="$2"
    local first_package
    first_package="$(
        sed -E $'s/\x1B\\[[0-9;]*m//g' "$LAST_LOG" |
        awk '/^[[:alnum:].+_-]+\/[[:alnum:].+_-]+[[:space:]]/ { sub(/\/.*/, "", $1); print $1; exit }'
    )"
    if [[ "$first_package" == "$expected" ]]; then
        ok "$message"
        return 0
    fi
    fail "$message (first result was '${first_package:-<none>}' in $LAST_LOG)"
    return 1
}

escape_ere() {
    sed 's/[][(){}.^$*+?|\\]/\\&/g' <<<"$1"
}

assert_path_exists() {
    local path="$1"
    local label="$2"
    if [[ -e "$path" ]]; then
        ok "$label"
        return 0
    fi
    fail "$label ($path missing)"
    return 1
}

count_cache_artifacts() {
    local total=0
    local dir
    for dir in \
        "$REPO_CACHE_DIR/gpkg" \
        "$REPO_CACHE_DIR/imported" \
        "$REPO_CACHE_DIR/debian/pool"; do
        [[ -d "$dir" ]] || continue
        local count
        count="$(find "$dir" -type f \( -name '*.gpkg' -o -name '*.deb' \) 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        total=$((total + count))
    done
    printf '%s\n' "$total"
}

snapshot_repo_source_files() {
    [[ -d "$SOURCES_DIR" ]] || return 0
    find "$SOURCES_DIR" -maxdepth 1 -type f -name '*.list' -print 2>/dev/null | sort
}

pkg_show_output() {
    "$GPKG_BIN" show "$1" 2>&1
}

pkg_available() {
    pkg_show_output "$1" >/dev/null 2>&1
}

pkg_installed_state() {
    local output line
    output="$(pkg_show_output "$1" || true)"
    line="$(sed -n 's/^  Installed:[[:space:]]*//p' <<<"$output" | head -n1)"
    case "$line" in
        no*) printf 'no\n' ;;
        yes\ \(*|yes*) printf 'installed\n' ;;
        base\ system*) printf 'base-system\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

pkg_installed_version() {
    local output line
    output="$(pkg_show_output "$1" || true)"
    line="$(sed -n 's/^  Installed:[[:space:]]*yes (\(.*\))$/\1/p' <<<"$output" | head -n1)"
    printf '%s\n' "$line"
}

mark_touched_package() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 0
    if [[ -z "${TRACKED_PACKAGES[$pkg]:-}" ]]; then
        TRACKED_PACKAGES["$pkg"]=1
        TOUCHED_PACKAGES+=("$pkg")
    fi
}

record_original_package_state() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 0
    if [[ -n "${ORIGINAL_STATE[$pkg]:-}" ]]; then
        return 0
    fi
    ORIGINAL_STATE["$pkg"]="$(pkg_installed_state "$pkg")"
    ORIGINAL_VERSION["$pkg"]="$(pkg_installed_version "$pkg")"
}

pick_transaction_packages() {
    local candidate
    local -a fresh=()
    local -a reinstallable=()
    for candidate in $TRANSACTION_CANDIDATES; do
        pkg_available "$candidate" || continue
        local state
        state="$(pkg_installed_state "$candidate")"
        case "$state" in
            no) fresh+=("$candidate") ;;
            installed) reinstallable+=("$candidate") ;;
        esac
    done

    if ((${#fresh[@]} >= 1)); then
        PRIMARY_PKG="${fresh[0]}"
    elif ((${#reinstallable[@]} >= 1)); then
        PRIMARY_PKG="${reinstallable[0]}"
        warn "Falling back to already-installed package fixture '$PRIMARY_PKG'. Cleanup will not remove it."
    else
        PRIMARY_PKG=""
    fi

    if ((${#fresh[@]} >= 2)); then
        SECONDARY_PKG="${fresh[1]}"
    elif ((${#fresh[@]} >= 1 && ${#reinstallable[@]} >= 1 && "${reinstallable[0]}" != "$PRIMARY_PKG" )); then
        SECONDARY_PKG="${reinstallable[0]}"
        warn "Second fixture '$SECONDARY_PKG' is already installed; coverage is still useful but less isolated."
    else
        SECONDARY_PKG=""
    fi

    PACKAGE_QUERY="$PRIMARY_PKG"
    [[ -n "$PACKAGE_QUERY" ]] || PACKAGE_QUERY="nano"
}

pick_protected_package() {
    local -a installed_candidates=()
    local -a base_candidates=()
    local candidate
    for candidate in $PROTECTED_CANDIDATES; do
        pkg_available "$candidate" || continue
        local state
        state="$(pkg_installed_state "$candidate")"
        case "$state" in
            installed)
                installed_candidates+=("$candidate")
                ;;
            base-system)
                base_candidates+=("$candidate")
                ;;
        esac
    done

    if ((${#installed_candidates[@]})); then
        PROTECTED_PKG="${installed_candidates[0]}"
        return 0
    fi
    if ((${#base_candidates[@]})); then
        PROTECTED_PKG="${base_candidates[0]}"
        return 0
    fi

    PROTECTED_PKG=""
}

verify_package_set() {
    local label="$1"
    shift
    local -a packages=("$@")
    local logfile failure_file pkg
    logfile="$REPORT_DIR/verify-$(sanitize_name "$label").log"
    failure_file="$REPORT_DIR/verify-$(sanitize_name "$label")-failures.txt"
    : >"$logfile"
    : >"$failure_file"

    local verified=0
    for pkg in "${packages[@]}"; do
        [[ -n "$pkg" ]] || continue
        if [[ "$(pkg_installed_state "$pkg")" == "no" ]]; then
            continue
        fi
        verified=$((verified + 1))
        {
            printf '### %s\n' "$pkg"
            printf '$ %q --jobs %q --verify %q\n' "$GPKG_WORKER_BIN" "$CPU_JOBS" "$pkg"
        } >>"$logfile"
        if "$GPKG_WORKER_BIN" --jobs "$CPU_JOBS" --verify "$pkg" >>"$logfile" 2>&1; then
            :
        else
            printf '%s\n' "$pkg" >>"$failure_file"
        fi
        printf '\n' >>"$logfile"
    done

    if [[ "$verified" -eq 0 ]]; then
        skip "No installed packages available for worker verification in '$label'"
        return 0
    fi

    if [[ -s "$failure_file" ]]; then
        fail "gpkg-worker verification failed for '$label'. See $failure_file"
        return 1
    fi

    ok "gpkg-worker verified $verified package(s) for '$label'"
    return 0
}

verify_all_registered_packages() {
    [[ -d "$INFO_DIR" ]] || { warn "Skipping full verify; $INFO_DIR is missing"; return 0; }
    mapfile -t all_pkgs < <(
        find "$INFO_DIR" -maxdepth 1 -type f -name '*.list' ! -name '*.system-backup.list' -printf '%f\n' 2>/dev/null \
            | sed 's/\.list$//' \
            | sort -u
    )
    verify_package_set "all-registered" "${all_pkgs[@]}"
}

cleanup() {
    [[ "$CLEANUP_DONE" -eq 0 ]] || return 0
    CLEANUP_DONE=1

    say
    say "== Cleanup =="

    if [[ "$KEEP_CHANGES" == "1" ]]; then
        warn "Leaving test-created package/repo changes in place because --keep-changes was requested"
        return 0
    fi

    local repo_file
    for repo_file in "${ADDED_REPO_FILES[@]}"; do
        [[ -f "$repo_file" ]] || continue
        if rm -f -- "$repo_file"; then
            ok "Removed temporary repo file $repo_file"
        else
            warn "Failed to remove temporary repo file $repo_file"
        fi
    done

    local -a remove_pkgs=()
    local pkg
    for pkg in "${TOUCHED_PACKAGES[@]}"; do
        [[ "${ORIGINAL_STATE[$pkg]:-unknown}" == "no" ]] || continue
        if [[ "$(pkg_installed_state "$pkg")" != "no" ]]; then
            remove_pkgs+=("$pkg")
        fi
    done

    if ((${#remove_pkgs[@]} == 0)); then
        ok "No transient test packages needed cleanup"
        return 0
    fi

    local remove_pkg
    for (( idx=${#remove_pkgs[@]}-1 ; idx>=0 ; idx-- )); do
        remove_pkg="${remove_pkgs[$idx]}"
        run_logged "cleanup-remove-$remove_pkg" \
            "$GPKG_BIN" -y remove --purge --autoremove "$remove_pkg"
        if [[ "$LAST_RC" -eq 0 ]]; then
            ok "Removed transient test package $remove_pkg during cleanup"
        else
            warn "Cleanup removal failed for $remove_pkg. See $LAST_LOG"
        fi
    done
}

print_summary() {
    [[ "$SUMMARY_PRINTED" -eq 0 ]] || return 0
    SUMMARY_PRINTED=1
    say
    say "== Summary =="
    say "Checks: $CHECKS"
    say "Warnings: $WARNS"
    say "Skips: $SKIPS"
    say "Failures: $FAILS"
    say "Report: $REPORT_DIR"
}

on_exit() {
    local rc=$?
    if [[ "$SUMMARY_PRINTED" -eq 0 ]]; then
        cleanup
        print_summary
    fi
    exit "$rc"
}

trap on_exit EXIT

preflight() {
    say "GeminiOS gpkg Robustness Test"
    say "gpkg: $GPKG_BIN"
    say "gpkg-worker: $GPKG_WORKER_BIN"
    say "State root: $ROOT"
    say "Report: $REPORT_DIR"
    say

    if [[ "$ALLOW_NON_ROOT" != "1" && "$(id -u)" -ne 0 ]]; then
        fail "This script expects root privileges for live gpkg transactions. Set GPKG_ALLOW_NON_ROOT=1 only if you know your gpkg binary is using a dev root."
        return 1
    fi

    assert_path_exists "$GPKG_BIN" "gpkg binary is present" || return 1
    assert_path_exists "$GPKG_WORKER_BIN" "gpkg-worker binary is present" || return 1
    return 0
}

run_cli_guardrail_tests() {
    say "== CLI Guardrails =="
    expect_success "gpkg-help-long" "$GPKG_BIN" --help || return 1
    assert_last_log_contains 'Usage: gpkg' "gpkg --help prints usage" || return 1

    expect_success "gpkg-help-short" "$GPKG_BIN" -h || return 1
    expect_success "gpkg-version" "$GPKG_BIN" --version || return 1
    assert_last_log_contains '^gpkg ' "gpkg --version prints version" || return 1

    expect_failure "gpkg-invalid-flag" "$GPKG_BIN" --definitely-not-a-real-flag || return 1
    assert_last_log_contains 'Unknown option' "Unknown top-level flag is rejected" || return 1

    expect_failure "gpkg-autoremove-extra-operand" "$GPKG_BIN" autoremove nano || return 1
    assert_last_log_contains 'does not take package names' "gpkg autoremove rejects package operands" || return 1

    expect_failure "gpkg-invalid-purge-command" "$GPKG_BIN" --purge update || return 1
    assert_last_log_contains '--purge is only valid' "gpkg rejects --purge on unsupported commands" || return 1

    expect_failure "gpkg-invalid-optional-flags" "$GPKG_BIN" --recommended-no search nano || return 1
    assert_last_log_contains 'optional dependency flags are only valid' "gpkg rejects optional dependency flags on non-transactional commands" || return 1

    expect_failure "gpkg-invalid-add-repo-scheme" "$GPKG_BIN" add-repo ftp://invalid.example/repo || return 1
    assert_last_log_contains 'Invalid repository URL' "gpkg add-repo rejects non-http(s) URLs" || return 1

    expect_failure "gpkg-worker-invalid-jobs" "$GPKG_WORKER_BIN" --jobs nope --verify nano || return 1
    assert_last_log_contains 'Invalid value for --jobs' "gpkg-worker rejects invalid --jobs value" || return 1
    say
}

run_repo_and_query_tests() {
    say "== Repo And Query Tests =="
    expect_success "gpkg-list-repos-before" "$GPKG_BIN" list-repos || return 1
    assert_last_log_contains 'Configured package sources:' "gpkg list-repos prints source header" || return 1

    expect_success "gpkg-update" "$GPKG_BIN" -y update || return 1
    assert_path_exists "$PACKAGES_JSON" "Merged package index exists after gpkg update" || return 1

    expect_success "gpkg-update-reuse" "$GPKG_BIN" -y update || return 1
    assert_last_log_contains 'Reused cached packages index|Updated packages index' \
        "gpkg update reuses cached Debian import data when possible" || return 1

    pick_transaction_packages
    if [[ -z "$PRIMARY_PKG" ]]; then
        fail "Could not discover any suitable package fixture from: $TRANSACTION_CANDIDATES"
        return 1
    fi
    ok "Selected primary fixture package: $PRIMARY_PKG"
    if [[ -n "$SECONDARY_PKG" ]]; then
        ok "Selected secondary fixture package: $SECONDARY_PKG"
    else
        warn "Only one safe fixture package was found; multi-package coverage will be reduced"
    fi

    expect_success "gpkg-search-fixture" "$GPKG_BIN" search "$PACKAGE_QUERY" || return 1
    assert_last_log_contains "$PACKAGE_QUERY" "gpkg search finds the chosen fixture query" || return 1
    assert_last_log_first_package_is "$PACKAGE_QUERY" "gpkg search ranks an exact package-name match first" || return 1

    expect_success "gpkg-show-primary" "$GPKG_BIN" show "$PRIMARY_PKG" || return 1
    assert_last_log_contains '^  Version:' "gpkg show prints package version" || return 1
    assert_last_log_contains '^  Installed:' "gpkg show prints installed state" || return 1

    if [[ -n "$SECONDARY_PKG" ]]; then
        expect_success "gpkg-show-secondary" "$GPKG_BIN" show "$SECONDARY_PKG" || return 1
    fi
    say
}

run_task_metapackage_tests() {
    say "== Task Metapackage Tests =="

    expect_success "gpkg-show-tasksel" "$GPKG_BIN" show tasksel || return 1
    assert_last_log_contains '^  Version:' "gpkg show exposes tasksel metadata" || return 1
    assert_last_log_not_contains 'Availability:[[:space:]]+unavailable.*apt' \
        "gpkg show no longer blames apt for tasksel availability" || return 1

    expect_success "gpkg-show-lxqt" "$GPKG_BIN" show lxqt || return 1
    assert_last_log_contains '^  Version:' "gpkg show resolves the lxqt metapackage" || return 1

    expect_success "gpkg-show-lxqt-core" "$GPKG_BIN" show lxqt-core || return 1
    assert_last_log_contains '^  Version:' "gpkg show resolves the lxqt-core metapackage" || return 1

    expect_success "gpkg-install-task-mate-desktop-dry-run" \
        bash -lc 'printf "n\n" | "$1" install --recommended-no --suggested-no task-mate-desktop' _ "$GPKG_BIN" || return 1
    assert_last_log_contains 'Do you want to continue\?|All packages are up to date\.' \
        "task-mate-desktop resolves to an install plan" || return 1
    assert_last_log_not_contains 'has no installation candidate|Unable to locate package|required dependency missing from imported set: tasksel|unresolved required dependency group\(s\): tasksel' \
        "task-mate-desktop no longer fails through tasksel" || return 1

    expect_success "gpkg-install-task-lxqt-desktop-dry-run" \
        bash -lc 'printf "n\n" | "$1" install --recommended-no --suggested-no task-lxqt-desktop' _ "$GPKG_BIN" || return 1
    assert_last_log_contains 'Do you want to continue\?|All packages are up to date\.' \
        "task-lxqt-desktop resolves to an install plan" || return 1
    assert_last_log_not_contains 'has no installation candidate|Unable to locate package|unresolved required dependency group\(s\): lxqt|required dependency missing from imported set: tasksel' \
        "task-lxqt-desktop no longer fails through lxqt or tasksel" || return 1

    expect_success "gpkg-install-task-gnome-desktop-dry-run" \
        bash -lc 'printf "n\n" | "$1" install --recommended-no --suggested-no task-gnome-desktop' _ "$GPKG_BIN" || return 1
    assert_last_log_contains 'Do you want to continue\?|All packages are up to date\.' \
        "task-gnome-desktop resolves to an install plan" || return 1
    assert_last_log_not_contains 'has no installation candidate|Unable to locate package|unresolved required dependency group\(s\): libpam-systemd, systemd' \
        "task-gnome-desktop no longer fails through rewritten logind/systemd dependencies" || return 1

    expect_failure "gpkg-install-apt-blocked" "$GPKG_BIN" install apt || return 1
    assert_last_log_contains 'blocked by GeminiOS import policy|has no installation candidate|available, but it is not installable' \
        "gpkg still blocks direct apt installation" || return 1
    say
}

run_doctor_and_selinux_tests() {
    say "== Doctor And SELinux Tests =="
    expect_success "gpkg-doctor" "$GPKG_BIN" doctor || return 1
    assert_last_log_contains '^gpkg doctor report:' "gpkg doctor prints its report header" || return 1
    assert_last_log_contains '^Repository configuration:' "gpkg doctor reports repository health" || return 1
    assert_last_log_contains '^Base system registry:' "gpkg doctor reports base-system health" || return 1
    assert_last_log_contains '^Upgrade dry-run:' "gpkg doctor reports upgrade-plan health" || return 1

    if [[ "$ROOT" == "/" ]]; then
        assert_path_exists "$BASE_SYSTEM_JSON" "Base-system registry exists on the live system" || return 1
        assert_last_log_not_contains '\[ERR\]' "gpkg doctor reports no hard errors on the live system" || return 1
    else
        warn "Skipping strict gpkg doctor health assertion because --state-root is not /"
    fi

    assert_path_exists "$SELINUX_CONFIG" "SELinux config exists in the tested root" || return 1
    expect_success "selinux-config-default" grep -Eq '^SELINUX=enforcing$' "$SELINUX_CONFIG" || return 1
    ok "Installed-system SELinux default is enforcing in /etc/selinux/config"

    if [[ "$ROOT" == "/" && -e "$LIVE_MARKER" ]]; then
        expect_success "selinux-live-runtime" bash -lc '
            if command -v getenforce >/dev/null 2>&1; then
                getenforce
            elif [[ -r /sys/fs/selinux/enforce ]]; then
                cat /sys/fs/selinux/enforce
            else
                exit 1
            fi
        ' || return 1
        assert_last_log_contains 'Permissive|Enforcing|0|1' "Live runtime exposes an enabled SELinux state" || return 1
        assert_last_log_not_contains 'Disabled' "Live runtime SELinux is not disabled" || return 1
    else
        skip "Skipping live SELinux runtime probe because this is not the active live root"
    fi
    say
}

run_upgrade_planner_guardrail_tests() {
    say "== Upgrade Planner Guardrails =="
    expect_success "gpkg-doctor-verbose" "$GPKG_BIN" -v doctor || return 1
    assert_last_log_not_contains 'Conflict detected in transaction!' \
        "verbose gpkg doctor does not surface planner conflicts" || return 1

    expect_success "gpkg-upgrade-planner-dry-run" \
        bash -lc 'printf "n\n" | "$1" upgrade --recommended-no --suggested-no' _ "$GPKG_BIN" || return 1
    assert_last_log_not_contains 'Conflict detected in transaction!' \
        "gpkg upgrade reaches the confirmation prompt without planner conflicts" || return 1
    assert_last_log_contains 'Do you want to continue\?|All packages are up to date\.' \
        "gpkg upgrade builds a usable plan before confirmation" || return 1
    say
}

run_protection_tests() {
    say "== Protection Tests =="
    pick_protected_package
    if [[ -z "$PROTECTED_PKG" ]]; then
        skip "No protected package candidate was available from: $PROTECTED_CANDIDATES"
        say
        return 0
    fi

    expect_failure "gpkg-protected-remove-$PROTECTED_PKG" "$GPKG_BIN" -y remove "$PROTECTED_PKG" || return 1
    assert_last_log_not_contains 'The following packages will be REMOVED:|Do you want to continue\?' \
        "gpkg does not build a removal transaction for protected package $PROTECTED_PKG" || return 1
    assert_last_log_contains "Refusing to remove|marked essential|upgradeable base system|base system image|priority is 'required'" \
        "gpkg refuses to remove protected package $PROTECTED_PKG" || return 1
    say
}

run_transaction_tests() {
    say "== Transaction Tests =="
    local -a install_set=("$PRIMARY_PKG")
    [[ -n "$SECONDARY_PKG" ]] && install_set+=("$SECONDARY_PKG")

    local pkg
    for pkg in "${install_set[@]}"; do
        record_original_package_state "$pkg"
        mark_touched_package "$pkg"
    done

    expect_success "gpkg-install-fixtures" \
        "$GPKG_BIN" -y install --recommended-no --suggested-no "${install_set[@]}" || return 1
    assert_last_log_contains 'Processing triggers\.\.\.' \
        "gpkg install processes post-transaction triggers for fixture installs" || return 1

    expect_success "gpkg-show-primary-installed" "$GPKG_BIN" show "$PRIMARY_PKG" || return 1
    assert_last_log_contains '^  Installed:[[:space:]]+yes|^  Installed:[[:space:]]+base system' \
        "gpkg show reports primary fixture as installed after install" || return 1

    if [[ -n "$SECONDARY_PKG" ]]; then
        expect_success "gpkg-show-secondary-installed" "$GPKG_BIN" show "$SECONDARY_PKG" || return 1
        assert_last_log_contains '^  Installed:[[:space:]]+yes|^  Installed:[[:space:]]+base system' \
            "gpkg show reports secondary fixture as installed after install" || return 1
    fi

    verify_package_set "fixtures-post-install" "${install_set[@]}" || return 1

    expect_success "gpkg-search-primary-installed" "$GPKG_BIN" search "$PRIMARY_PKG" || return 1
    assert_last_log_first_package_is "$PRIMARY_PKG" "gpkg search keeps the exact primary fixture first after install" || return 1
    assert_last_log_contains "^.*$(escape_ere "$PRIMARY_PKG")/.*\\[installed" \
        "gpkg search reports installed status for the primary fixture" || return 1

    expect_success "gpkg-reinstall-primary" \
        "$GPKG_BIN" -y install --reinstall --recommended-no --suggested-no "$PRIMARY_PKG" || return 1
    assert_last_log_contains 'reused from cache|0 B transferred' \
        "gpkg reinstall reuses or avoids redownloading cached package data" || return 1

    expect_success "gpkg-remove-primary-purge" \
        "$GPKG_BIN" -y remove --purge "$PRIMARY_PKG" || return 1
    expect_success "gpkg-show-primary-after-purge" "$GPKG_BIN" show "$PRIMARY_PKG" || return 1
    assert_last_log_contains '^  Installed:[[:space:]]+no' \
        "gpkg show reports the primary fixture as removed after purge" || return 1

    expect_success "gpkg-reinstall-primary-after-purge" \
        "$GPKG_BIN" -y install --recommended-no --suggested-no "$PRIMARY_PKG" || return 1
    assert_last_log_contains 'reused from cache|0 B transferred' \
        "gpkg reinstall after purge still benefits from cache before clean" || return 1

    if [[ -n "$SECONDARY_PKG" ]]; then
        expect_success "gpkg-remove-secondary-autoremove-purge" \
            "$GPKG_BIN" -y remove --purge --autoremove "$SECONDARY_PKG" || return 1
        expect_success "gpkg-show-secondary-after-remove" "$GPKG_BIN" show "$SECONDARY_PKG" || return 1
        assert_last_log_contains '^  Installed:[[:space:]]+no' \
            "gpkg show reports the secondary fixture as removed after remove --autoremove --purge" || return 1
    else
        skip "Skipping combined remove --autoremove --purge test because only one fixture package was available"
    fi

    expect_success "gpkg-autoremove-standalone" "$GPKG_BIN" -y autoremove --purge || return 1
    say
}

run_clean_and_index_tests() {
    say "== Clean And Index Tests =="
    local pre_clean_count post_clean_count
    pre_clean_count="$(count_cache_artifacts)"
    expect_success "gpkg-clean" "$GPKG_BIN" -y clean || return 1

    assert_path_exists "$PACKAGES_JSON" "gpkg clean keeps the merged package index" || return 1
    expect_success "gpkg-show-primary-after-clean" "$GPKG_BIN" show "$PRIMARY_PKG" || return 1

    post_clean_count="$(count_cache_artifacts)"
    if [[ "$pre_clean_count" =~ ^[0-9]+$ && "$post_clean_count" =~ ^[0-9]+$ ]]; then
        if (( post_clean_count <= pre_clean_count )); then
            ok "gpkg clean reduced or preserved cache artifact count ($pre_clean_count -> $post_clean_count)"
        else
            fail "gpkg clean increased cache artifact count unexpectedly ($pre_clean_count -> $post_clean_count)"
            return 1
        fi
    else
        warn "Could not compute cache artifact counts around gpkg clean"
    fi

    expect_success "gpkg-update-after-clean" "$GPKG_BIN" -y update || return 1
    say
}

run_repair_and_worker_tests() {
    say "== Repair And Worker Tests =="
    expect_success "gpkg-repair" "$GPKG_BIN" -y repair --recommended-no --suggested-no || return 1

    expect_success "gpkg-worker-refresh-runtime-linker-state" \
        "$GPKG_WORKER_BIN" --jobs "$CPU_JOBS" --refresh-runtime-linker-state || return 1

    local temp_root source_elf
    temp_root="$(mktemp -d /tmp/gpkg-shadow-runtime.XXXXXX)"
    source_elf="$(pick_runtime_elf_source || true)"
    if [[ -z "$source_elf" ]]; then
        rm -rf "$temp_root"
        skip "Skipping shadowed runtime cleanup regression; no reusable ELF source was found"
    else
        mkdir -p \
            "$temp_root/etc" \
            "$temp_root/lib/x86_64-linux-gnu" \
            "$temp_root/usr/lib/x86_64-linux-gnu" \
            "$temp_root/var/lib/gpkg/info"
        cp -f "$source_elf" "$temp_root/usr/lib/x86_64-linux-gnu/libgpkgshadow.so.1.1"
        cp -f "$source_elf" "$temp_root/usr/lib/x86_64-linux-gnu/libgpkgshadow.so.1.2"
        ln -s libgpkgshadow.so.1.2 "$temp_root/usr/lib/x86_64-linux-gnu/libgpkgshadow.so.1"
        ln -s libgpkgshadow.so.9 "$temp_root/usr/lib/x86_64-linux-gnu/libgpkgshadow.so"
        ln -s libgpkgbroken.so.1 "$temp_root/usr/lib/x86_64-linux-gnu/libgpkgbroken.so"
        printf '/usr/lib/x86_64-linux-gnu/libgpkgshadow.so.1.1\n' \
            > "$temp_root/var/lib/gpkg/info/libgpkgshadowtest.list"

        expect_success "gpkg-worker-shadowed-runtime-prune" \
            "$GPKG_WORKER_BIN" --jobs "$CPU_JOBS" --root "$temp_root" --refresh-runtime-linker-state --verbose || {
                rm -rf "$temp_root"
                return 1
            }

        if [[ ! -e "$temp_root/usr/lib/x86_64-linux-gnu/libgpkgshadow.so.1.1" ]]; then
            fail "gpkg-worker removed the package-owned runtime provider in the fake upgrade root"
            rm -rf "$temp_root"
            return 1
        fi
        if [[ -e "$temp_root/usr/lib/x86_64-linux-gnu/libgpkgshadow.so.1.2" ]]; then
            fail "gpkg-worker left an unowned shadowed runtime provider behind in the fake upgrade root"
            rm -rf "$temp_root"
            return 1
        fi
        if [[ ! -L "$temp_root/usr/lib/x86_64-linux-gnu/libgpkgshadow.so" ]]; then
            fail "gpkg-worker did not repair the broken runtime linker symlink in the fake upgrade root"
            rm -rf "$temp_root"
            return 1
        fi
        if [[ ! -e "$temp_root/usr/lib/x86_64-linux-gnu/libgpkgshadow.so" ]]; then
            fail "gpkg-worker left the repaired runtime linker symlink dangling in the fake upgrade root"
            rm -rf "$temp_root"
            return 1
        fi
        if [[ -e "$temp_root/usr/lib/x86_64-linux-gnu/libgpkgbroken.so" || -L "$temp_root/usr/lib/x86_64-linux-gnu/libgpkgbroken.so" ]]; then
            fail "gpkg-worker left a broken unowned runtime linker symlink behind in the fake upgrade root"
            rm -rf "$temp_root"
            return 1
        fi
        ok "gpkg-worker repaired broken linker symlinks and pruned stale runtime leftovers in an isolated fake upgrade root"
        rm -rf "$temp_root"
    fi

    verify_package_set "touched-packages" "${TOUCHED_PACKAGES[@]}" || return 1
    if [[ "$VERIFY_ALL" == "1" ]]; then
        verify_all_registered_packages || return 1
    else
        skip "Full registered-package verification was disabled by --verify-touched-only / GPKG_TEST_VERIFY_ALL=0"
    fi
    say
}

run_optional_repo_test() {
    say "== Optional Repo Add Test =="
    if [[ -z "$POSITIVE_REPO_URL" ]]; then
        skip "Positive add-repo test skipped. Supply --repo URL or GPKG_TEST_REPO_URL to enable it."
        say
        return 0
    fi

    local before_file after_file
    mapfile -t before_file < <(snapshot_repo_source_files)

    expect_success "gpkg-add-repo-positive" "$GPKG_BIN" -y add-repo "$POSITIVE_REPO_URL" || return 1
    expect_success "gpkg-list-repos-after-add" "$GPKG_BIN" list-repos || return 1
    assert_last_log_contains "$(escape_ere "$POSITIVE_REPO_URL")" \
        "gpkg list-repos shows the newly added repository" || return 1

    mapfile -t after_file < <(snapshot_repo_source_files)
    local candidate
    for candidate in "${after_file[@]}"; do
        local found=0
        local prior
        for prior in "${before_file[@]}"; do
            [[ "$candidate" == "$prior" ]] && { found=1; break; }
        done
        if [[ "$found" -eq 0 ]]; then
            ADDED_REPO_FILES+=("$candidate")
        fi
    done

    if ((${#ADDED_REPO_FILES[@]} == 0)); then
        warn "Positive add-repo test succeeded but no new repo file was detected for cleanup"
    else
        ok "Tracked ${#ADDED_REPO_FILES[@]} repo file(s) for cleanup"
    fi
    say
}

run_optional_upgrade_test() {
    say "== Optional Full Upgrade Test =="
    if [[ "$FULL_UPGRADE" != "1" ]]; then
        skip "Full gpkg upgrade test skipped. Use --with-upgrade or GPKG_TEST_FULL_UPGRADE=1 to enable it."
        say
        return 0
    fi

    warn "Running full 'gpkg upgrade -y'. This is intentionally aggressive and not reversible."
    expect_success "gpkg-full-upgrade" \
        "$GPKG_BIN" -y upgrade --recommended-no --suggested-no || return 1
    say
}

main_rc=0

preflight || main_rc=1
if [[ "$main_rc" -eq 0 ]]; then run_cli_guardrail_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_repo_and_query_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_task_metapackage_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_doctor_and_selinux_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_upgrade_planner_guardrail_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_protection_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_transaction_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_clean_and_index_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_repair_and_worker_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_optional_repo_test || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_optional_upgrade_test || main_rc=1; fi

cleanup
print_summary
trap - EXIT

if [[ "$main_rc" -ne 0 || "$FAILS" -ne 0 ]]; then
    exit 1
fi
exit 0
