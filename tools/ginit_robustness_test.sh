#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: ginit_robustness_test.sh [options]

Focused robustness test for the GeminiOS ginit init system.

Warning:
  This script can mutate live ginit state:
  - creates temporary .gservice files
  - starts and stops temporary services
  - enables and disables temporary services
  - temporarily edits /etc/ginit/boot-services.conf

Best used on a disposable GeminiOS VM / ISO / test machine.

Options:
  -h, --help              Show this help text
  --keep-changes          Do not remove temporary test services/configuration on exit
  --ginit PATH            ginit binary to use
  --boot-init PATH        boot entrypoint binary to probe, default /sbin/init
  --allow-non-root        Allow non-root execution; live mutation tests will be skipped

Environment overrides:
  GINIT_BIN
  GINIT_BOOT_INIT
  GINIT_TEST_KEEP_CHANGES=0|1
  GINIT_TEST_ALLOW_NON_ROOT=0|1
  GINIT_TEST_REPORT_DIR=/tmp/...
  GINIT_TEST_PREFIX=name-prefix

Examples:
  sudo ./tools/ginit_robustness_test.sh
  sudo GINIT_TEST_PREFIX=my-ginit-probe ./tools/ginit_robustness_test.sh
EOF
}

KEEP_CHANGES="${GINIT_TEST_KEEP_CHANGES:-0}"
ALLOW_NON_ROOT="${GINIT_TEST_ALLOW_NON_ROOT:-0}"
GINIT_BIN="${GINIT_BIN:-}"
BOOT_INIT_BIN="${GINIT_BOOT_INIT:-/sbin/init}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --keep-changes)
            KEEP_CHANGES=1
            ;;
        --ginit)
            [[ $# -ge 2 ]] || { echo "Missing value for --ginit" >&2; exit 1; }
            GINIT_BIN="$2"
            shift
            ;;
        --boot-init)
            [[ $# -ge 2 ]] || { echo "Missing value for --boot-init" >&2; exit 1; }
            BOOT_INIT_BIN="$2"
            shift
            ;;
        --allow-non-root)
            ALLOW_NON_ROOT=1
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="${GINIT_TEST_REPORT_DIR:-/tmp/ginit-robustness-$STAMP}"
TMP_ROOT="/tmp/ginit-robustness-work-$STAMP"
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
SUMMARY_PRINTED=0
CLEANUP_DONE=0
LIVE_MUTATION_OK=0
PID1_IS_GINIT=0
CONTROL_SOCKET_PATH=""
ADMIN_BOOT_BACKUP=""
ADMIN_BOOT_EXISTED=0

AVAILABLE_SERVICES_DIR="/usr/lib/ginit/services"
SYSTEM_SERVICES_DIR="/etc/ginit/services/system"
ADMIN_BOOT_SERVICES="/etc/ginit/boot-services.conf"
VENDOR_BOOT_SERVICES="/usr/lib/ginit/boot-services.conf"
GINIT_LOG_DIR="/var/log/ginit"

TEST_PREFIX="${GINIT_TEST_PREFIX:-ginit-robust-$STAMP}"
SERVICE_STEADY="${TEST_PREFIX}-steady"
SERVICE_ONESHOT="${TEST_PREFIX}-oneshot"
SERVICE_RESTART="${TEST_PREFIX}-restart"
SERVICE_STUBBORN="${TEST_PREFIX}-stubborn"
SERVICE_BAD_ENV="${TEST_PREFIX}-bad-env"
SERVICE_CYCLE_A="${TEST_PREFIX}-cycle-a"
SERVICE_CYCLE_B="${TEST_PREFIX}-cycle-b"
SERVICE_CHECK="${TEST_PREFIX}-check"
SERVICE_INVALID="${TEST_PREFIX}-invalid"
MISSING_DEP_SERVICE="${TEST_PREFIX}-missing"
UNKNOWN_PRESET_SERVICE="${TEST_PREFIX}-ghost"

declare -a TEMP_SERVICE_NAMES=(
    "$SERVICE_STEADY"
    "$SERVICE_ONESHOT"
    "$SERVICE_RESTART"
    "$SERVICE_STUBBORN"
    "$SERVICE_BAD_ENV"
    "$SERVICE_CYCLE_A"
    "$SERVICE_CYCLE_B"
    "$SERVICE_CHECK"
    "$SERVICE_INVALID"
)

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

escape_ere() {
    sed 's/[][(){}.^$*+?|\\]/\\&/g' <<<"$1"
}

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
    if grep -Eq -- "$pattern" "$LAST_LOG"; then
        ok "$message"
        return 0
    fi
    fail "$message (pattern not found in $LAST_LOG)"
    return 1
}

assert_last_log_not_contains() {
    local pattern="$1"
    local message="$2"
    if grep -Eq -- "$pattern" "$LAST_LOG"; then
        fail "$message (unexpected pattern found in $LAST_LOG)"
        return 1
    fi
    ok "$message"
    return 0
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

assert_path_not_exists() {
    local path="$1"
    local label="$2"
    if [[ ! -e "$path" ]]; then
        ok "$label"
        return 0
    fi
    fail "$label ($path unexpectedly exists)"
    return 1
}

service_available_path() {
    printf '%s/%s.gservice\n' "$AVAILABLE_SERVICES_DIR" "$1"
}

service_enabled_path() {
    printf '%s/%s.gservice\n' "$SYSTEM_SERVICES_DIR" "$1"
}

service_log_path() {
    printf '%s/%s.log\n' "$GINIT_LOG_DIR" "$1"
}

wait_for_file_contains() {
    local file="$1"
    local pattern="$2"
    local timeout_s="$3"
    local start=$SECONDS
    while (( SECONDS - start < timeout_s )); do
        if [[ -f "$file" ]] && grep -Eq -- "$pattern" "$file"; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

wait_for_file_lines_at_least() {
    local file="$1"
    local min_lines="$2"
    local timeout_s="$3"
    local start=$SECONDS
    local count=0
    while (( SECONDS - start < timeout_s )); do
        if [[ -f "$file" ]]; then
            count="$(wc -l <"$file" | tr -d ' ')"
            [[ "$count" =~ ^[0-9]+$ ]] || count=0
            if (( count >= min_lines )); then
                return 0
            fi
        fi
        sleep 0.2
    done
    return 1
}

wait_for_ginit_output() {
    local subcmd="$1"
    local service="$2"
    local pattern="$3"
    local timeout_s="$4"
    local start=$SECONDS
    local out=""
    while (( SECONDS - start < timeout_s )); do
        out="$("$GINIT_BIN" "$subcmd" "$service" 2>&1 || true)"
        if grep -Eq -- "$pattern" <<<"$out"; then
            printf '%s\n' "$out" >"$REPORT_DIR/last-wait-output.txt"
            return 0
        fi
        sleep 0.2
    done
    printf '%s\n' "$out" >"$REPORT_DIR/last-wait-output.txt"
    return 1
}

write_helper_scripts() {
    mkdir -p "$TMP_ROOT"

    cat >"$TMP_ROOT/steady.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
marker_dir="$1"
service_name="$2"
trap 'exit 0' TERM INT
printf '%s started\n' "$service_name" >>"$marker_dir/steady.events"
while :; do
    sleep 1
done
EOF

    cat >"$TMP_ROOT/oneshot_env.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
marker_dir="$1"
printf '%s|%s|%s\n' "${FILE_TOKEN:-}" "${INLINE_TOKEN:-}" "$PWD" >"$marker_dir/oneshot.out"
EOF

    cat >"$TMP_ROOT/flappy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
marker_dir="$1"
printf '%s\n' "$(date +%s)" >>"$marker_dir/restart.count"
sleep 1
exit 1
EOF

    cat >"$TMP_ROOT/stubborn.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
marker_dir="$1"
trap '' TERM INT
printf 'started\n' >>"$marker_dir/stubborn.started"
while :; do
    sleep 1
done
EOF

    chmod +x \
        "$TMP_ROOT/steady.sh" \
        "$TMP_ROOT/oneshot_env.sh" \
        "$TMP_ROOT/flappy.sh" \
        "$TMP_ROOT/stubborn.sh"

    cat >"$TMP_ROOT/oneshot.env" <<'EOF'
FILE_TOKEN=file-token
EOF
}

write_service_file() {
    local service_name="$1"
    local body="$2"
    mkdir -p "$AVAILABLE_SERVICES_DIR"
    printf '%s\n' "$body" >"$(service_available_path "$service_name")"
}

write_common_test_services() {
    write_service_file "$SERVICE_STEADY" "service \"$SERVICE_STEADY\" {
    meta {
        description = \"Temporary steady service\"
    }

    process {
        type = \"simple\"
        commands {
            start = \"$TMP_ROOT/steady.sh $TMP_ROOT $SERVICE_STEADY\"
        }

        lifecycle {
            stop_timeout = \"1s\"
        }
    }
}"

    write_service_file "$SERVICE_ONESHOT" "service \"$SERVICE_ONESHOT\" {
    meta {
        description = \"Temporary oneshot env test\"
    }

    process {
        type = \"oneshot\"
        work_dir = \"$TMP_ROOT\"

        commands {
            start_pre = \"printf pre > $TMP_ROOT/oneshot.pre\"
            start = \"$TMP_ROOT/oneshot_env.sh $TMP_ROOT\"
        }
    }

    env {
        load_file = \"$TMP_ROOT/oneshot.env\"
        vars {
            INLINE_TOKEN = \"inline-token\"
        }
    }

    security {
        no_new_privileges = true
    }
}"

    write_service_file "$SERVICE_RESTART" "service \"$SERVICE_RESTART\" {
    meta {
        description = \"Temporary restart-loop test\"
    }

    process {
        type = \"simple\"
        commands {
            start = \"$TMP_ROOT/flappy.sh $TMP_ROOT\"
        }

        lifecycle {
            restart_policy = \"always\"
            restart_delay = \"100ms\"
            stop_timeout = \"500ms\"
        }
    }
}"

    write_service_file "$SERVICE_STUBBORN" "service \"$SERVICE_STUBBORN\" {
    meta {
        description = \"Temporary SIGKILL stop-path test\"
    }

    process {
        type = \"simple\"
        commands {
            start = \"$TMP_ROOT/stubborn.sh $TMP_ROOT\"
        }

        lifecycle {
            stop_timeout = \"200ms\"
        }
    }
}"

    write_service_file "$SERVICE_BAD_ENV" "service \"$SERVICE_BAD_ENV\" {
    meta {
        description = \"Temporary missing env file test\"
    }

    process {
        type = \"simple\"
        commands {
            start = \"$TMP_ROOT/steady.sh $TMP_ROOT $SERVICE_BAD_ENV\"
        }
    }

    env {
        load_file = \"$TMP_ROOT/does-not-exist.env\"
    }
}"

    write_service_file "$SERVICE_CYCLE_A" "service \"$SERVICE_CYCLE_A\" {
    meta {
        description = \"Temporary dependency cycle A\"
        deps {
            requires = [\"$SERVICE_CYCLE_B\"]
        }
    }

    process {
        type = \"simple\"
        commands {
            start = \"$TMP_ROOT/steady.sh $TMP_ROOT $SERVICE_CYCLE_A\"
        }
    }
}"

    write_service_file "$SERVICE_CYCLE_B" "service \"$SERVICE_CYCLE_B\" {
    meta {
        description = \"Temporary dependency cycle B\"
        deps {
            requires = [\"$SERVICE_CYCLE_A\"]
        }
    }

    process {
        type = \"simple\"
        commands {
            start = \"$TMP_ROOT/steady.sh $TMP_ROOT $SERVICE_CYCLE_B\"
        }
    }
}"
}

write_config_error_test_services() {
    write_service_file "$SERVICE_CHECK" "service \"$SERVICE_CHECK\" {
    meta {
        description = \"Temporary configuration checker target\"
        deps {
            requires = [\"$MISSING_DEP_SERVICE\"]
        }
    }

    process {
        type = \"oneshot\"
        commands {
            start = \"$TMP_ROOT/oneshot_env.sh $TMP_ROOT\"
        }
    }

    env {
        load_file = \"$TMP_ROOT/missing-check.env\"
    }
}"

    write_service_file "$SERVICE_INVALID" "service \"$SERVICE_INVALID\" {
    meta {
        description = \"Broken parser test\"
    }

    process {
        type = \"simple\"
        commands {
            start = \"$TMP_ROOT/steady.sh $TMP_ROOT $SERVICE_INVALID\"
        }

        lifecycle {
            restart_policy = \"definitely-not-valid\"
        }
    }
}"
}

backup_admin_boot_preset_once() {
    [[ -n "$ADMIN_BOOT_BACKUP" ]] && return 0
    mkdir -p "$TMP_ROOT"
    ADMIN_BOOT_BACKUP="$TMP_ROOT/admin-boot-services.conf.backup"
    if [[ -e "$ADMIN_BOOT_SERVICES" ]]; then
        ADMIN_BOOT_EXISTED=1
        cp -a "$ADMIN_BOOT_SERVICES" "$ADMIN_BOOT_BACKUP"
    else
        ADMIN_BOOT_EXISTED=0
        : >"$ADMIN_BOOT_BACKUP"
    fi
}

restore_admin_boot_preset() {
    [[ -n "$ADMIN_BOOT_BACKUP" ]] || return 0
    if [[ "$ADMIN_BOOT_EXISTED" -eq 1 ]]; then
        cp -a "$ADMIN_BOOT_BACKUP" "$ADMIN_BOOT_SERVICES"
    else
        rm -f "$ADMIN_BOOT_SERVICES"
    fi
}

cleanup() {
    [[ "$CLEANUP_DONE" -eq 0 ]] || return 0
    CLEANUP_DONE=1

    say
    say "== Cleanup =="

    if [[ "$KEEP_CHANGES" == "1" ]]; then
        warn "Leaving temporary ginit services in place because --keep-changes was requested"
        return 0
    fi

    restore_admin_boot_preset

    local service
    for service in "${TEMP_SERVICE_NAMES[@]}"; do
        if [[ "$LIVE_MUTATION_OK" -eq 1 ]]; then
            run_logged "cleanup-stop-$service" "$GINIT_BIN" stop "$service"
            if [[ "$LAST_RC" -eq 0 ]]; then
                ok "Stopped temporary service $service during cleanup"
            fi
            run_logged "cleanup-disable-$service" "$GINIT_BIN" disable "$service"
            if [[ "$LAST_RC" -eq 0 ]]; then
                ok "Disabled temporary service $service during cleanup"
            fi
        fi
        rm -f -- "$(service_enabled_path "$service")"
        rm -f -- "$(service_available_path "$service")"
        rm -f -- "$(service_log_path "$service")"
    done

    if rm -rf -- "$TMP_ROOT"; then
        ok "Removed temporary workspace $TMP_ROOT"
    else
        warn "Failed to remove temporary workspace $TMP_ROOT"
    fi
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
    say "GeminiOS ginit Robustness Test"
    say "ginit: ${GINIT_BIN:-<auto>}"
    say "boot init: $BOOT_INIT_BIN"
    say "Report: $REPORT_DIR"
    say

    need_cmd bash
    need_cmd grep
    need_cmd sed
    need_cmd awk
    need_cmd ps
    need_cmd readlink
    need_cmd find
    need_cmd sort

    GINIT_BIN="$(resolve_binary "$GINIT_BIN" ginit /bin/ginit /home/creitin/Documents/geminios/ginit/bin/ginit)" || {
        fail "Unable to locate ginit binary"
        return 1
    }

    assert_path_exists "$GINIT_BIN" "ginit binary is present" || return 1

    if [[ "$ALLOW_NON_ROOT" != "1" && "$(id -u)" -ne 0 ]]; then
        fail "This script expects root privileges for live ginit mutation tests. Use --allow-non-root only for read-only probes."
        return 1
    fi

    local pid1_exe pid1_comm
    pid1_exe="$(readlink -f /proc/1/exe 2>/dev/null || true)"
    pid1_comm="$(ps -p 1 -o comm= 2>/dev/null | awk '{print $1}')"
    if [[ "$pid1_exe" == *"/ginit" || "$pid1_comm" == "ginit" ]]; then
        PID1_IS_GINIT=1
        ok "PID 1 is ginit ($pid1_exe)"
    else
        warn "PID 1 is not ginit (comm=${pid1_comm:-unknown}, exe=${pid1_exe:-unknown}); live supervision tests will be skipped"
    fi

    if [[ "$(id -u)" -eq 0 && "$PID1_IS_GINIT" -eq 1 ]]; then
        LIVE_MUTATION_OK=1
    fi

    if [[ "$LIVE_MUTATION_OK" -eq 1 ]]; then
        expect_success "ginit-status-preflight" "$GINIT_BIN" status || return 1
        assert_last_log_not_contains 'Could not connect to ginit' "ginit status can talk to the live control socket" || return 1

        local socket
        for socket in /run/ginit.sock /dev/ginit.sock /tmp/ginit.sock; do
            if [[ -S "$socket" ]]; then
                CONTROL_SOCKET_PATH="$socket"
                break
            fi
        done
        if [[ -n "$CONTROL_SOCKET_PATH" ]]; then
            ok "Detected live ginit control socket at $CONTROL_SOCKET_PATH"
        else
            fail "Could not find a live ginit control socket even though PID 1 is ginit"
            return 1
        fi
    else
        skip "Live mutation tests are disabled because this is not a root GeminiOS session with ginit as PID 1"
    fi

    return 0
}

run_cli_guardrail_tests() {
    say "== CLI Guardrails =="
    expect_success "ginit-no-args" "$GINIT_BIN" || return 1
    assert_last_log_contains 'status \[service\]|Show this help message' "running ginit without arguments prints the ginit help menu" || return 1

    expect_success "ginit-help" "$GINIT_BIN" help || return 1
    assert_last_log_contains 'check \[service\]|restart <service>' "ginit help shows management commands" || return 1

    expect_failure "ginit-invalid-command" "$GINIT_BIN" definitely-not-a-real-command || return 1
    assert_last_log_contains 'Unknown command' "unknown ginit commands are rejected" || return 1

    expect_failure "ginit-start-missing-service" "$GINIT_BIN" start || return 1
    assert_last_log_contains "requires a service name" "ginit start requires a service name" || return 1

    if [[ -x "$BOOT_INIT_BIN" ]]; then
        expect_failure "boot-init-no-args" "$BOOT_INIT_BIN" || return 1
        assert_last_log_contains "GeminiOS init entry point|Use 'ginit <command>'" "boot init entrypoint does not expose the interactive ginit menu" || return 1
        assert_last_log_not_contains 'status \[service\]' "boot init entrypoint no longer prints the ginit help menu" || return 1

        expect_failure "boot-init-help" "$BOOT_INIT_BIN" help || return 1
        assert_last_log_contains "Use 'ginit help'" "boot init entrypoint redirects users to ginit help" || return 1
    else
        warn "Skipping /sbin/init UX probe because $BOOT_INIT_BIN is not executable"
    fi

    assert_path_exists "/sbin/init" "/sbin/init exists as the boot entrypoint" || return 1
    assert_path_not_exists "/bin/init" "/bin/init is absent so the interactive CLI remains ginit-only" || return 1
    say
}

run_baseline_configuration_tests() {
    say "== Baseline Configuration =="
    expect_success "ginit-check-baseline" "$GINIT_BIN" check || return 1
    assert_last_log_contains '^ginit configuration check:' "ginit check prints its report header" || return 1

    if [[ -f "$VENDOR_BOOT_SERVICES" ]]; then
        ok "Vendor boot preset exists at $VENDOR_BOOT_SERVICES"
    else
        warn "Vendor boot preset is missing at $VENDOR_BOOT_SERVICES"
    fi

    if [[ -f "$AVAILABLE_SERVICES_DIR/dbus.gservice" ]]; then
        expect_success "ginit-show-dbus" "$GINIT_BIN" show dbus || return 1
        assert_last_log_contains 'Source: |Restart policy:' "ginit show prints service details for shipped services" || return 1
    else
        warn "Skipping shipped dbus show probe because $AVAILABLE_SERVICES_DIR/dbus.gservice is missing"
    fi
    say
}

run_static_bug_finding_tests() {
    say "== Static Bug-Finding Tests =="
    if [[ "$(id -u)" -ne 0 ]]; then
        skip "Skipping service-file mutation tests because root privileges are required"
        say
        return 0
    fi

    write_helper_scripts
    write_common_test_services
    write_config_error_test_services

    backup_admin_boot_preset_once
    {
        if [[ "$ADMIN_BOOT_EXISTED" -eq 1 ]]; then
            cat "$ADMIN_BOOT_BACKUP"
        fi
        printf '%s\n' "$UNKNOWN_PRESET_SERVICE"
    } >"$ADMIN_BOOT_SERVICES"

    expect_failure "ginit-check-invalid-config" "$GINIT_BIN" check || return 1
    assert_last_log_contains "$(escape_ere "$SERVICE_INVALID")" "ginit check surfaces parser errors from broken .gservice files" || return 1
    assert_last_log_contains 'unsupported restart_policy' "ginit check shows the parser failure reason" || return 1

    rm -f -- "$(service_available_path "$SERVICE_INVALID")"

    expect_failure "ginit-check-temp-service" "$GINIT_BIN" check "$SERVICE_CHECK" || return 1
    assert_last_log_contains "requires missing service '$MISSING_DEP_SERVICE'" "ginit check catches missing required services" || return 1
    assert_last_log_contains "references missing env file $TMP_ROOT/missing-check.env" "ginit check warns about missing env files" || return 1
    assert_last_log_contains "Boot preset references unknown service '$UNKNOWN_PRESET_SERVICE'" "ginit check catches broken boot preset references" || return 1

    expect_success "ginit-show-temp-check-service" "$GINIT_BIN" show "$SERVICE_CHECK" || return 1
    assert_last_log_contains "Env file: $TMP_ROOT/missing-check.env" "ginit show exposes env file metadata for unloaded services" || return 1
    assert_last_log_contains "Requires: $MISSING_DEP_SERVICE" "ginit show exposes dependency metadata for unloaded services" || return 1

    restore_admin_boot_preset
    rm -f -- "$(service_available_path "$SERVICE_CHECK")"
    expect_success "ginit-check-after-static-cleanup" "$GINIT_BIN" check || return 1
    say
}

run_live_supervision_tests() {
    say "== Live Supervision Tests =="
    if [[ "$LIVE_MUTATION_OK" -ne 1 ]]; then
        skip "Skipping live supervision tests because ginit is not active as PID 1 in this session"
        say
        return 0
    fi

    write_helper_scripts
    write_common_test_services

    expect_success "ginit-enable-steady" "$GINIT_BIN" enable "$SERVICE_STEADY" || return 1
    assert_path_exists "$(service_enabled_path "$SERVICE_STEADY")" "ginit enable created the persistent service symlink" || return 1
    expect_success "ginit-status-steady-enabled" "$GINIT_BIN" status "$SERVICE_STEADY" || return 1
    assert_last_log_contains 'Persistent: Yes' "ginit status reports persistent enablement" || return 1

    expect_success "ginit-disable-steady" "$GINIT_BIN" disable "$SERVICE_STEADY" || return 1
    assert_path_not_exists "$(service_enabled_path "$SERVICE_STEADY")" "ginit disable removes the persistent service symlink" || return 1

    expect_success "ginit-start-steady" "$GINIT_BIN" start "$SERVICE_STEADY" || return 1
    if wait_for_ginit_output status "$SERVICE_STEADY" 'Status: Running' 5; then
        ok "steady test service reached the Running state"
    else
        fail "steady test service never reached the Running state"
        return 1
    fi
    expect_success "ginit-show-steady-running" "$GINIT_BIN" show "$SERVICE_STEADY" || return 1
    assert_last_log_contains 'PID: [0-9]+' "ginit show exposes the running PID" || return 1
    assert_path_exists "$(service_log_path "$SERVICE_STEADY")" "ginit created a log file for the steady test service" || return 1

    expect_success "ginit-restart-steady" "$GINIT_BIN" restart "$SERVICE_STEADY" || return 1
    assert_last_log_contains 'Started '"$SERVICE_STEADY"'|Stopped '"$SERVICE_STEADY"'' "ginit restart stops and starts the service" || return 1

    expect_success "ginit-stop-steady" "$GINIT_BIN" stop "$SERVICE_STEADY" || return 1
    if wait_for_ginit_output status "$SERVICE_STEADY" 'Status: Stopped' 5; then
        ok "steady test service returned to the Stopped state"
    else
        fail "steady test service never returned to the Stopped state"
        return 1
    fi

    expect_success "ginit-start-oneshot" "$GINIT_BIN" start "$SERVICE_ONESHOT" || return 1
    assert_last_log_contains 'finished successfully' "oneshot services report successful completion" || return 1
    assert_path_exists "$TMP_ROOT/oneshot.pre" "oneshot StartPre command ran" || return 1
    assert_path_exists "$TMP_ROOT/oneshot.out" "oneshot service wrote its output marker" || return 1
    if grep -Eq '^file-token\|inline-token\|'"$(escape_ere "$TMP_ROOT")"'$' "$TMP_ROOT/oneshot.out"; then
        ok "oneshot service observed env file variables, inline vars, and work_dir"
    else
        fail "oneshot service output did not contain the expected env/workdir data"
        return 1
    fi
    expect_success "ginit-status-oneshot" "$GINIT_BIN" status "$SERVICE_ONESHOT" || return 1
    assert_last_log_contains 'Status: Finished' "ginit status reports finished oneshot services" || return 1

    expect_success "ginit-start-oneshot-again" "$GINIT_BIN" start "$SERVICE_ONESHOT" || return 1
    assert_last_log_contains 'already finished successfully' "ginit does not rerun completed oneshot services" || return 1

    expect_success "ginit-start-bad-env" "$GINIT_BIN" start "$SERVICE_BAD_ENV" || return 1
    if wait_for_file_contains "$(service_log_path "$SERVICE_BAD_ENV")" 'unable to open env file' 5; then
        ok "ginit captured missing env file failures in the service log"
    else
        fail "ginit did not log the missing env file failure for $SERVICE_BAD_ENV"
        return 1
    fi
    if wait_for_ginit_output show "$SERVICE_BAD_ENV" 'Last result: exit 126|Last result: exit 1|Status: Stopped' 5; then
        ok "ginit reflected the failed startup result for the bad-env service"
    else
        fail "ginit never exposed the bad-env startup failure in service status"
        return 1
    fi

    expect_failure "ginit-start-cycle-a" "$GINIT_BIN" start "$SERVICE_CYCLE_A" || return 1
    assert_last_log_contains 'Dependency cycle detected|Failed to start requirement' "ginit rejects cyclic service dependencies" || return 1

    expect_success "ginit-start-restart-loop" "$GINIT_BIN" start "$SERVICE_RESTART" || return 1
    if wait_for_file_lines_at_least "$TMP_ROOT/restart.count" 2 6; then
        ok "restart-on-failure test service restarted multiple times"
    else
        fail "restart-on-failure test service did not restart multiple times"
        return 1
    fi
    if wait_for_ginit_output show "$SERVICE_RESTART" 'Restart count: [1-9]' 6; then
        ok "ginit show reports restart counts for flapping services"
    else
        fail "ginit never exposed a restart count for the flapping service"
        return 1
    fi
    if wait_for_ginit_output status "$SERVICE_RESTART" 'Status: Running' 3; then
        ok "restart-loop test service was observed in the Running state"
    else
        warn "restart-loop service was not caught in the Running state before cleanup"
    fi
    expect_success "ginit-stop-restart-loop" "$GINIT_BIN" stop "$SERVICE_RESTART" || return 1

    expect_success "ginit-start-stubborn" "$GINIT_BIN" start "$SERVICE_STUBBORN" || return 1
    if wait_for_ginit_output status "$SERVICE_STUBBORN" 'Status: Running' 5; then
        ok "stubborn test service reached the Running state"
    else
        fail "stubborn test service never reached the Running state"
        return 1
    fi
    expect_success "ginit-stop-stubborn" "$GINIT_BIN" stop "$SERVICE_STUBBORN" || return 1
    assert_last_log_contains 'after SIGKILL' "ginit escalates to SIGKILL when a service ignores SIGTERM" || return 1

    expect_success "ginit-check-post-live-tests" "$GINIT_BIN" check || return 1
    say
}

main_rc=0

preflight || main_rc=1
if [[ "$main_rc" -eq 0 ]]; then run_cli_guardrail_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_baseline_configuration_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_static_bug_finding_tests || main_rc=1; fi
if [[ "$main_rc" -eq 0 ]]; then run_live_supervision_tests || main_rc=1; fi

cleanup
print_summary
trap - EXIT

if [[ "$main_rc" -ne 0 || "$FAILS" -ne 0 ]]; then
    exit 1
fi
exit 0
