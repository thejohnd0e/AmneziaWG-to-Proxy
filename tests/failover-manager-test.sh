#!/bin/sh

set -u

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$TEST_DIR")
MANAGER="$PROJECT_DIR/scripts/failover-manager.sh"
TUN_SETUP="$PROJECT_DIR/scripts/ensure-tun.sh"
TMP_ROOT=$(mktemp -d)
MANAGER_PID=""

# Kill switch stand-in: logs its calls to $KS_LOG and fails with $KS_DNS_STATUS
# (dns-open) or $KS_APPLY_STATUS (apply) when those are set
KILLSWITCH="$TMP_ROOT/killswitch"
printf '%s\n' \
    '#!/bin/sh' \
    'echo "killswitch $*" >> "${KS_LOG:-/dev/null}"' \
    'if [ "$1" = apply ]; then exit "${KS_APPLY_STATUS:-0}"; fi' \
    'exit "${KS_DNS_STATUS:-0}"' > "$KILLSWITCH"
chmod +x "$KILLSWITCH"
export KILLSWITCH

cleanup() {
    if [ -n "$MANAGER_PID" ]; then
        kill "$MANAGER_PID" 2>/dev/null || true
        wait "$MANAGER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_file_exists() {
    [ -f "$1" ] || fail "expected file to exist: $1"
}

assert_no_configs() {
    if find "$1" -maxdepth 1 -type f -name '*.conf' | grep -q .; then
        fail "expected no configs in: $1"
    fi
}

wait_for_file() {
    file="$1"
    attempts=0
    while [ ! -f "$file" ] && [ "$attempts" -lt 50 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
}

make_success_commands() {
    command_dir="$1"
    mkdir -p "$command_dir"

    printf '%s\n' '#!/bin/sh' 'exit 0' > "$command_dir/awg-quick"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$command_dir/check-tunnel"
    printf '%s\n' '#!/bin/sh' 'echo "0.001 0.050"' > "$command_dir/curl"
    chmod +x "$command_dir/awg-quick" "$command_dir/check-tunnel" "$command_dir/curl"
}

test_missing_wg_directory_is_created() {
    root="$TMP_ROOT/create-directory"
    mkdir -p "$root/configs" "$root/bad"
    printf '%s\n' '[Interface]' 'PrivateKey = test' 'DNS = 1.1.1.1' > "$root/configs/working.conf"
    make_success_commands "$root/bin"

    PATH="$root/bin:$PATH" \
    CONFIG_DIR="$root/configs" \
    BAD_DIR="$root/bad" \
    ACTIVE_MARKER="$root/active" \
    FAILURE_FILE="$root/failures" \
    WG_CONF="$root/missing/amneziawg/wg0.conf" \
    CHECK_TUNNEL="$root/bin/check-tunnel" \
    TUN_SETUP="$TUN_SETUP" \
    TUN_DEVICE=/dev/null \
    FAILOVER_INTERVAL=1 \
        sh "$MANAGER" > "$root/manager.log" 2>&1 &
    MANAGER_PID=$!

    wait_for_file "$root/active"

    assert_file_exists "$root/active"
    assert_file_exists "$root/missing/amneziawg/wg0.conf"
    assert_file_exists "$root/configs/working.conf"
    assert_no_configs "$root/bad"
    grep -q '^DNS = 1.1.1.1$' "$root/configs/working.conf" \
        || fail "source config DNS directive should remain unchanged"
    if grep -q '^[[:space:]]*DNS[[:space:]]*=' "$root/missing/amneziawg/wg0.conf"; then
        fail "staged config should not contain a DNS directive"
    fi

    kill "$MANAGER_PID"
    wait "$MANAGER_PID" 2>/dev/null || true
    MANAGER_PID=""
    echo "PASS: missing WireGuard directory is created"
}

test_empty_config_directory_waits_for_config() {
    root="$TMP_ROOT/empty-directory"
    mkdir -p "$root/configs" "$root/bad" "$root/wg" "$root/bin"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" checked >> "$CHECK_CALLS"' 'exit 0' > "$root/bin/check-tunnel"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$root/bin/awg-quick"
    printf '%s\n' '#!/bin/sh' 'echo "0.001 0.050"' > "$root/bin/curl"
    chmod +x "$root/bin/awg-quick" "$root/bin/check-tunnel" "$root/bin/curl"

    PATH="$root/bin:$PATH" \
    CONFIG_DIR="$root/configs" \
    BAD_DIR="$root/bad" \
    ACTIVE_MARKER="$root/active" \
    FAILURE_FILE="$root/failures" \
    WG_CONF="$root/wg/wg0.conf" \
    CHECK_TUNNEL="$root/bin/check-tunnel" \
    CHECK_CALLS="$root/check-calls" \
    TUN_SETUP="$TUN_SETUP" \
    TUN_DEVICE=/dev/null \
    CONFIG_POLL_INTERVAL=0.1 \
    FAILOVER_INTERVAL=1 \
        sh "$MANAGER" > "$root/manager.log" 2>&1 &
    MANAGER_PID=$!

    sleep 0.3
    [ ! -e "$root/check-calls" ] \
        || fail "health check should not run without a selected config"
    assert_no_configs "$root/bad"

    printf '%s\n' '[Interface]' 'PrivateKey = test' > "$root/configs/working.conf"
    wait_for_file "$root/active"

    assert_file_exists "$root/active"
    assert_file_exists "$root/configs/working.conf"
    assert_no_configs "$root/bad"
    if grep -qE 'basename:|cp: .*option|Failed to move' "$root/manager.log"; then
        fail "empty config directory was treated as a config path"
    fi

    kill "$MANAGER_PID"
    wait "$MANAGER_PID" 2>/dev/null || true
    MANAGER_PID=""
    echo "PASS: empty config directory waits for a real config"
}

test_copy_failure_does_not_quarantine_config() {
    root="$TMP_ROOT/copy-failure"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    printf '%s\n' '[Interface]' 'PrivateKey = test' > "$root/configs/must-stay.conf"
    make_success_commands "$root/bin"
    printf '%s\n' '#!/bin/sh' 'exit 1' > "$root/bin/cp"
    chmod +x "$root/bin/cp"

    if PATH="$root/bin:$PATH" \
        CONFIG_DIR="$root/configs" \
        BAD_DIR="$root/bad" \
        ACTIVE_MARKER="$root/active" \
        FAILURE_FILE="$root/failures" \
        WG_CONF="$root/wg/wg0.conf" \
        CHECK_TUNNEL="$root/bin/check-tunnel" \
        TUN_SETUP="$TUN_SETUP" \
        TUN_DEVICE=/dev/null \
            sh "$MANAGER" > "$root/manager.log" 2>&1; then
        fail "manager should fail when the config cannot be staged"
    fi

    assert_file_exists "$root/configs/must-stay.conf"
    assert_no_configs "$root/bad"
    grep -q 'Fatal staging error' "$root/manager.log" \
        || fail "expected a fatal staging error in the log"
    echo "PASS: copy failure does not quarantine config"
}

test_transient_initial_health_failure_is_retried() {
    root="$TMP_ROOT/transient-health"
    mkdir -p "$root/configs" "$root/bad" "$root/wg" "$root/bin"
    printf '%s\n' '[Interface]' 'PrivateKey = test' > "$root/configs/working.conf"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$root/bin/awg-quick"
    printf '%s\n' \
        '#!/bin/sh' \
        'count=$(cat "$CHECK_COUNT" 2>/dev/null || echo 0)' \
        'count=$((count + 1))' \
        'echo "$count" > "$CHECK_COUNT"' \
        '[ "$count" -ge 3 ]' > "$root/bin/check-tunnel"
    printf '%s\n' '#!/bin/sh' 'echo "0.001 0.050"' > "$root/bin/curl"
    chmod +x "$root/bin/awg-quick" "$root/bin/check-tunnel" "$root/bin/curl"

    PATH="$root/bin:$PATH" \
    CONFIG_DIR="$root/configs" \
    BAD_DIR="$root/bad" \
    ACTIVE_MARKER="$root/active" \
    FAILURE_FILE="$root/failures" \
    WG_CONF="$root/wg/wg0.conf" \
    CHECK_TUNNEL="$root/bin/check-tunnel" \
    CHECK_COUNT="$root/check-count" \
    STARTUP_CHECKS=3 \
    TUN_SETUP="$TUN_SETUP" \
    TUN_DEVICE=/dev/null \
    FAILOVER_FAILURES=3 \
    FAILOVER_INTERVAL="${TEST_FAILOVER_INTERVAL:-0.1}" \
        sh "$MANAGER" > "$root/manager.log" 2>&1 &
    MANAGER_PID=$!

    wait_for_file "$root/active"

    assert_file_exists "$root/active"
    assert_file_exists "$root/configs/working.conf"
    assert_no_configs "$root/bad"
    [ "$(cat "$root/check-count")" -ge 3 ] \
        || fail "expected initial health check to be retried"

    kill "$MANAGER_PID"
    wait "$MANAGER_PID" 2>/dev/null || true
    MANAGER_PID=""
    echo "PASS: transient initial health failure is retried"
}

test_fastest_config_is_selected() {
    root="$TMP_ROOT/speed-test"
    mkdir -p "$root/configs" "$root/bad" "$root/wg" "$root/bin"
    printf '%s\n' '[Interface]' 'PrivateKey = slow' 'Address = 10.0.0.1/32' \
        > "$root/configs/slow.conf"
    printf '%s\n' '[Interface]' 'PrivateKey = fast' 'Address = 10.0.0.2/32' \
        > "$root/configs/fast.conf"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$root/bin/awg-quick"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$root/bin/check-tunnel"
    printf '%s\n' \
        '#!/bin/sh' \
        'if grep -q "10.0.0.2" "$WG_CONF" 2>/dev/null; then echo "0.001 0.051"; else echo "0.001 0.501"; fi' \
        > "$root/bin/curl"
    chmod +x "$root/bin/awg-quick" "$root/bin/check-tunnel" "$root/bin/curl"

    PATH="$root/bin:$PATH" \
    CONFIG_DIR="$root/configs" \
    BAD_DIR="$root/bad" \
    ACTIVE_MARKER="$root/active" \
    FAILURE_FILE="$root/failures" \
    WG_CONF="$root/wg/wg0.conf" \
    CHECK_TUNNEL="$root/bin/check-tunnel" \
    TUN_SETUP="$TUN_SETUP" \
    TUN_DEVICE=/dev/null \
    SPEED_TEST=1 \
    FAILOVER_INTERVAL=1 \
        sh "$MANAGER" > "$root/manager.log" 2>&1 &
    MANAGER_PID=$!

    wait_for_file "$root/active"

    assert_file_exists "$root/active"
    grep -q 'fast.conf' "$root/active" \
        || fail "expected the fastest config to be selected"
    assert_file_exists "$root/configs/fast.conf"
    assert_file_exists "$root/configs/slow.conf"
    assert_no_configs "$root/bad"

    kill "$MANAGER_PID"
    wait "$MANAGER_PID" 2>/dev/null || true
    MANAGER_PID=""
    echo "PASS: fastest config is selected"
}

test_tun_device_is_created() {
    root="$TMP_ROOT/tun-device"
    mkdir -p "$root/bin"
    printf '%s\n' '#!/bin/sh' ': > "$1"' > "$root/bin/mknod"
    chmod +x "$root/bin/mknod"

    PATH="$root/bin:$PATH" TUN_DEVICE="$root/dev/net/tun" sh "$TUN_SETUP" \
        || fail "TUN setup should create a missing device"
    [ -e "$root/dev/net/tun" ] || fail "expected TUN device to be created"
    echo "PASS: missing TUN device is created"
}

wait_for_log() {
    file="$1"
    pattern="$2"
    attempts=0
    while ! grep -q "$pattern" "$file" 2>/dev/null && [ "$attempts" -lt 100 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
}

# Fakes for the restart tests. awg-quick counts "up" calls; check-tunnel fails
# while $root/broken exists and the staged config is still the first one.
make_restart_commands() {
    root="$1"
    mkdir -p "$root/bin"
    printf '%s\n' \
        '#!/bin/sh' \
        '[ "$1" = up ] || exit 0' \
        'count=$(cat "$UP_COUNT" 2>/dev/null || echo 0)' \
        'echo $((count + 1)) > "$UP_COUNT"' > "$root/bin/awg-quick"
    printf '%s\n' '#!/bin/sh' 'echo "0.001 0.050"' > "$root/bin/curl"
    chmod +x "$root/bin/awg-quick" "$root/bin/curl"
}

run_restart_manager() {
    root="$1"
    PATH="$root/bin:$PATH" \
    CONFIG_DIR="$root/configs" \
    BAD_DIR="$root/bad" \
    ACTIVE_MARKER="$root/active" \
    FAILURE_FILE="$root/failures" \
    PENDING_FAILURE_FILE="$root/pending-failures" \
    WG_CONF="$root/wg/wg0.conf" \
    CHECK_TUNNEL="$root/bin/check-tunnel" \
    UP_COUNT="$root/up-count" \
    BROKEN="$root/broken" \
    ROOT="$root" \
    TUN_SETUP="$TUN_SETUP" \
    TUN_DEVICE=/dev/null \
    SPEED_TEST="${SPEED_TEST:-0}" \
    QUARANTINE_AFTER="${QUARANTINE_AFTER:-1}" \
    RANK_BUDGET="${RANK_BUDGET:-300}" \
    FAILOVER_FAILURES="${FAILOVER_FAILURES:-2}" \
    FAILOVER_INTERVAL=0.1 \
    CONFIG_POLL_INTERVAL=0.2 \
    TUNNEL_RESTARTS="${TUNNEL_RESTARTS:-1}" \
        sh "$MANAGER" > "$root/manager.log" 2>&1 &
    MANAGER_PID=$!
}

stop_manager() {
    kill "$MANAGER_PID"
    wait "$MANAGER_PID" 2>/dev/null || true
    MANAGER_PID=""
}

test_dead_tunnel_is_restarted_not_quarantined() {
    root="$TMP_ROOT/restart-recovers"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    printf '%s\n' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    make_restart_commands "$root"
    # healthy until $root/broken appears; a restart (second "up") heals it
    printf '%s\n' \
        '#!/bin/sh' \
        '[ ! -f "$BROKEN" ] || [ "$(cat "$UP_COUNT")" -gt 1 ]' > "$root/bin/check-tunnel"
    chmod +x "$root/bin/check-tunnel"

    run_restart_manager "$root"
    wait_for_file "$root/active"
    : > "$root/broken"
    wait_for_log "$root/manager.log" "Tunnel recovered after restart"

    grep -q "Tunnel recovered after restart" "$root/manager.log" \
        || fail "expected the tunnel to be restarted and recover"
    assert_file_exists "$root/configs/a.conf"
    assert_no_configs "$root/bad"
    [ "$(cat "$root/up-count")" -ge 2 ] || fail "expected awg-quick up to run again"

    stop_manager
    echo "PASS: dead tunnel is restarted, config is not quarantined"
}

test_startup_probes_wait_longer_than_monitoring() {
    root="$TMP_ROOT/startup-timeout"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    printf '%s
' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    make_restart_commands "$root"
    printf '%s
' '#!/bin/sh' 'echo "$FAILOVER_TIMEOUT" >> "$ROOT/timeouts"' 'exit 0' > "$root/bin/check-tunnel"
    chmod +x "$root/bin/check-tunnel"

    FAILOVER_TIMEOUT=3 STARTUP_TIMEOUT=9 run_restart_manager "$root"
    wait_for_file "$root/active"
    attempts=0
    while ! grep -q '^3$' "$root/timeouts" 2>/dev/null && [ "$attempts" -lt 100 ]; do
        sleep 0.1; attempts=$((attempts + 1))
    done
    stop_manager

    [ "$(sed -n '1p' "$root/timeouts")" = 9 ] || fail "startup probe must use STARTUP_TIMEOUT"
    grep -q '^3$' "$root/timeouts" || fail "monitoring probe must use FAILOVER_TIMEOUT"
    echo "PASS: startup probes wait longer than monitoring probes"
}

test_only_config_is_never_quarantined() {
    root="$TMP_ROOT/only-config"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    printf '%s\n' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    make_restart_commands "$root"
    # healthy until $root/broken appears, then dead for good
    printf '%s\n' '#!/bin/sh' '[ ! -f "$BROKEN" ]' > "$root/bin/check-tunnel"
    chmod +x "$root/bin/check-tunnel"

    run_restart_manager "$root"
    wait_for_file "$root/active"
    : > "$root/broken"
    wait_for_log "$root/manager.log" "Only config a.conf: keeping it"

    grep -q "Only config a.conf: keeping it" "$root/manager.log" \
        || fail "expected the only config to be kept"
    assert_file_exists "$root/configs/a.conf"
    assert_no_configs "$root/bad"

    stop_manager
    echo "PASS: the only config is never quarantined"
}

test_unrecoverable_config_is_replaced_after_restarts() {
    root="$TMP_ROOT/restart-then-switch"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    printf '%s\n' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    printf '%s\n' '[Interface]' 'PrivateKey = b' > "$root/configs/b.conf"
    make_restart_commands "$root"
    # config a dies for good once $root/broken appears; config b is fine
    printf '%s\n' \
        '#!/bin/sh' \
        '[ ! -f "$BROKEN" ] || ! grep -q "PrivateKey = a" "$WG_CONF"' > "$root/bin/check-tunnel"
    sed -i 's|"\$WG_CONF"|"$ROOT/wg/wg0.conf"|' "$root/bin/check-tunnel"
    chmod +x "$root/bin/check-tunnel"

    run_restart_manager "$root"
    wait_for_file "$root/active"
    : > "$root/broken"
    wait_for_file "$root/bad/a.conf"
    wait_for_log "$root/manager.log" "Config b.conf is ACTIVE"

    assert_file_exists "$root/bad/a.conf"
    assert_file_exists "$root/configs/b.conf"
    grep -q "Restarting tunnel (1 / 1): a.conf" "$root/manager.log" \
        || fail "expected a restart before quarantining a.conf"
    grep -q "b.conf" "$root/active" || fail "expected b.conf to become active"

    stop_manager
    echo "PASS: unrecoverable config is replaced after restarts"
}

test_failed_health_check_is_quarantined_only_after_repeated_strikes() {
    root="$TMP_ROOT/strikes"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    printf '%s\n' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    printf '%s\n' '[Interface]' 'PrivateKey = b' > "$root/configs/b.conf"
    make_restart_commands "$root"
    # config a never passes the health check, config b always does
    printf '%s\n' '#!/bin/sh' '! grep -q "PrivateKey = a" "$ROOT/wg/wg0.conf"' > "$root/bin/check-tunnel"
    chmod +x "$root/bin/check-tunnel"

    export SPEED_TEST=1 QUARANTINE_AFTER=2 FAILOVER_FAILURES=1 FAST_START=0
    run_restart_manager "$root"
    wait_for_file "$root/active"
    grep -q "b.conf" "$root/active" || fail "expected b.conf to become active"
    assert_file_exists "$root/configs/a.conf"
    [ ! -f "$root/bad/a.conf" ] || fail "one failed health check must not quarantine a.conf"
    [ "$(cat "$root/bad/.strikes/a.conf")" = 1 ] || fail "expected one recorded strike for a.conf"
    stop_manager

    # the strike survives a restart: the second failure quarantines a.conf
    rm -f "$root/active"
    run_restart_manager "$root"
    wait_for_file "$root/bad/a.conf"
    assert_file_exists "$root/bad/a.conf"
    [ ! -f "$root/configs/a.conf" ] || fail "a.conf should have left the config directory"
    stop_manager
    unset SPEED_TEST QUARANTINE_AFTER FAILOVER_FAILURES FAST_START
    echo "PASS: a failed health check is quarantined only after repeated strikes"
}

test_ranking_stops_after_budget_once_a_config_works() {
    root="$TMP_ROOT/rank-budget"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    for name in a b c; do
        printf '%s\n' '[Interface]' "PrivateKey = $name" > "$root/configs/$name.conf"
    done
    make_restart_commands "$root"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$root/bin/check-tunnel"
    chmod +x "$root/bin/check-tunnel"

    export SPEED_TEST=1 RANK_BUDGET=0
    run_restart_manager "$root"
    wait_for_file "$root/active"
    wait_for_log "$root/manager.log" "ACTIVE"
    stop_manager
    unset SPEED_TEST RANK_BUDGET

    grep -q "Ranking budget" "$root/manager.log" || fail "expected the ranking budget to be hit"
    grep -q "Speed test: a.conf = " "$root/manager.log" || fail "expected the first config to be tested"
    if grep -q "Speed test: c.conf = " "$root/manager.log"; then
        fail "ranking should have stopped before testing c.conf"
    fi
    assert_file_exists "$root/configs/c.conf"
    assert_no_configs "$root/bad"
    echo "PASS: ranking stops after the budget once a config works"
}

test_fast_start_uses_last_working_config() {
    root="$TMP_ROOT/fast-start"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    for name in a b c; do
        printf '%s\n' '[Interface]' "PrivateKey = $name" > "$root/configs/$name.conf"
    done
    printf '%s\n' 'c.conf' > "$root/bad/.last_active"
    make_restart_commands "$root"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$root/bin/check-tunnel"
    chmod +x "$root/bin/check-tunnel"

    export SPEED_TEST=1
    run_restart_manager "$root"
    wait_for_file "$root/active"
    wait_for_log "$root/manager.log" "ACTIVE"
    stop_manager
    unset SPEED_TEST

    grep -q "c.conf" "$root/active" || fail "expected the last working config c.conf to be active"
    grep -q "Fast start" "$root/manager.log" || fail "expected a fast start"
    if grep -q "Speed test: [a-z]*\.conf" "$root/manager.log"; then
        fail "fast start must not rank the other configs"
    fi
    echo "PASS: fast start uses the last working config"
}

test_fast_start_falls_back_to_ranking() {
    root="$TMP_ROOT/fast-start-fallback"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    for name in a b c; do
        printf '%s\n' '[Interface]' "PrivateKey = $name" > "$root/configs/$name.conf"
    done
    printf '%s\n' 'c.conf' > "$root/bad/.last_active"
    make_restart_commands "$root"
    # the remembered config c is dead, the others are fine
    printf '%s\n' '#!/bin/sh' '! grep -q "PrivateKey = c" "$ROOT/wg/wg0.conf"' > "$root/bin/check-tunnel"
    chmod +x "$root/bin/check-tunnel"

    export SPEED_TEST=1 QUARANTINE_AFTER=5 FAILOVER_FAILURES=1
    run_restart_manager "$root"
    wait_for_file "$root/active"
    wait_for_log "$root/manager.log" "ACTIVE"
    stop_manager
    unset SPEED_TEST QUARANTINE_AFTER FAILOVER_FAILURES

    grep -q "Fast start" "$root/manager.log" || fail "expected a fast start attempt"
    grep -q "Ranking configs" "$root/manager.log" || fail "expected the ranking after the failed fast start"
    if grep -q "c.conf" "$root/active"; then
        fail "the dead remembered config must not become active"
    fi
    assert_file_exists "$root/configs/c.conf"
    [ "$(cat "$root/bad/.last_active")" = "$(basename "$(cat "$root/active")")" ] \
        || fail "expected the new active config to be remembered"
    echo "PASS: fast start falls back to ranking"
}

make_logging_commands() {
    root="$1"
    make_success_commands "$root/bin"
    printf '%s\n' '#!/bin/sh' 'echo "awg-quick $1" >> "$KS_LOG"' 'exit 0' > "$root/bin/awg-quick"
    chmod +x "$root/bin/awg-quick"
}

test_tunnel_is_brought_up_inside_kill_switch_window() {
    root="$TMP_ROOT/kill-switch-order"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    printf '%s\n' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    make_logging_commands "$root"

    export KS_LOG="$root/calls.log"
    run_restart_manager "$root"
    wait_for_file "$root/active"
    stop_manager
    unset KS_LOG

    expected=$(printf '%s\n' 'killswitch dns-open' 'awg-quick up' 'killswitch apply')
    [ "$(head -n 3 "$root/calls.log")" = "$expected" ] \
        || fail "expected dns-open, awg-quick up, apply in that order, got: $(cat "$root/calls.log")"
    echo "PASS: tunnel is brought up inside the kill switch window"
}

test_tunnel_is_not_started_when_kill_switch_cannot_be_armed() {
    root="$TMP_ROOT/kill-switch-unarmed"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    printf '%s\n' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    make_logging_commands "$root"

    export KS_LOG="$root/calls.log" KS_DNS_STATUS=1
    run_restart_manager "$root"
    wait "$MANAGER_PID"
    status=$?
    MANAGER_PID=""
    unset KS_LOG KS_DNS_STATUS

    [ "$status" -eq 1 ] || fail "expected the manager to stop with status 1, got $status"
    if grep -q 'awg-quick up' "$root/calls.log" 2>/dev/null; then
        fail "tunnel must not start while the kill switch is not armed"
    fi
    grep -q "Kill switch could not be armed" "$root/manager.log" \
        || fail "expected the unarmed kill switch to be reported"
    [ ! -f "$root/active" ] || fail "no config may become active without a kill switch"
    echo "PASS: tunnel is not started when the kill switch cannot be armed"
}

test_tunnel_is_torn_down_when_kill_switch_cannot_be_finalized() {
    root="$TMP_ROOT/kill-switch-finalize"
    mkdir -p "$root/configs" "$root/bad" "$root/wg"
    printf '%s\n' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    make_logging_commands "$root"

    export KS_LOG="$root/calls.log" KS_APPLY_STATUS=1
    run_restart_manager "$root"
    wait "$MANAGER_PID"
    status=$?
    MANAGER_PID=""
    unset KS_LOG KS_APPLY_STATUS

    [ "$status" -eq 1 ] || fail "expected the manager to stop with status 1, got $status"
    expected=$(printf '%s\n' 'killswitch dns-open' 'awg-quick up' 'killswitch apply' 'awg-quick down')
    [ "$(head -n 4 "$root/calls.log")" = "$expected" ] \
        || fail "expected the tunnel to be taken down after a failed finalize, got: $(cat "$root/calls.log")"
    [ ! -f "$root/active" ] || fail "no config may become active without a finalized kill switch"
    echo "PASS: tunnel is taken down when the kill switch cannot be finalized"
}

test_all_awg_start_failures_preserve_every_config_and_strike() {
    root="$TMP_ROOT/start-failure-outage"
    mkdir -p "$root/configs" "$root/bad" "$root/wg" "$root/bin" "$root/bad/.strikes"
    printf '%s\n' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    printf '%s\n' '[Interface]' 'PrivateKey = b' > "$root/configs/b.conf"
    printf '%s\n' '2' > "$root/bad/.strikes/a.conf"
    make_success_commands "$root/bin"
    printf '%s\n' '#!/bin/sh' '[ "$1" = up ] && exit 1' 'exit 0' > "$root/bin/awg-quick"
    chmod +x "$root/bin/awg-quick"

    SPEED_TEST=1 QUARANTINE_AFTER=3 FAST_START=0 run_restart_manager "$root"
    sleep 0.5
    stop_manager

    assert_file_exists "$root/configs/a.conf"
    assert_file_exists "$root/configs/b.conf"
    assert_no_configs "$root/bad"
    [ "$(cat "$root/bad/.strikes/a.conf")" = 2 ] \
        || fail "an all-start-failure round must not add strikes"
    grep -q "No working configs found" "$root/manager.log" \
        || fail "expected the manager to report that no candidate became active"
    echo "PASS: all awg-quick failures preserve configs and pending strikes"
}

test_all_health_failures_preserve_existing_strikes() {
    root="$TMP_ROOT/health-failure-outage"
    mkdir -p "$root/configs" "$root/bad" "$root/wg" "$root/bin" "$root/bad/.strikes"
    printf '%s\n' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    printf '%s\n' '[Interface]' 'PrivateKey = b' > "$root/configs/b.conf"
    printf '%s\n' '2' > "$root/bad/.strikes/a.conf"
    make_success_commands "$root/bin"
    printf '%s\n' '#!/bin/sh' 'exit 1' > "$root/bin/check-tunnel"
    chmod +x "$root/bin/check-tunnel"

    SPEED_TEST=1 QUARANTINE_AFTER=3 FAST_START=0 STARTUP_CHECKS=1 run_restart_manager "$root"
    sleep 0.5
    stop_manager

    assert_file_exists "$root/configs/a.conf"
    assert_file_exists "$root/configs/b.conf"
    assert_no_configs "$root/bad"
    [ "$(cat "$root/bad/.strikes/a.conf")" = 2 ] \
        || fail "a round with no healthy candidate must not add strikes"
    grep -q "No config became healthy" "$root/manager.log" \
        || fail "expected all unhealthy candidates to be reported"
    echo "PASS: all health failures preserve configs and existing strikes"
}

test_pending_strike_commits_only_after_replacement_is_active() {
    root="$TMP_ROOT/pending-strike-commit"
    mkdir -p "$root/configs" "$root/bad/.strikes" "$root/wg" "$root/bin"
    printf '%s\n' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    printf '%s\n' '[Interface]' 'PrivateKey = b' > "$root/configs/b.conf"
    printf '%s\n' '2' > "$root/bad/.strikes/a.conf"
    make_success_commands "$root/bin"
    printf '%s\n' \
        '#!/bin/sh' \
        '[ "$1" = up ] || exit 0' \
        'grep -q "PrivateKey = a" "$WG_CONF" && exit 1' \
        'exit 0' > "$root/bin/awg-quick"
    chmod +x "$root/bin/awg-quick"

    SPEED_TEST=1 QUARANTINE_AFTER=3 FAST_START=0 run_restart_manager "$root"
    wait_for_file "$root/active"

    grep -q 'b.conf' "$root/active" || fail "expected healthy replacement b to become active"
    assert_file_exists "$root/bad/a.conf"
    assert_file_exists "$root/configs/b.conf"

    stop_manager
    echo "PASS: pending strike commits after replacement activation"
}

test_existing_strikes_clear_only_after_stable_health() {
    root="$TMP_ROOT/stable-strike-clear"
    mkdir -p "$root/configs" "$root/bad/.strikes" "$root/wg" "$root/bin"
    printf '%s\n' '[Interface]' 'PrivateKey = a' > "$root/configs/a.conf"
    printf '%s\n' '2' > "$root/bad/.strikes/a.conf"
    make_success_commands "$root/bin"

    SPEED_TEST=1 FAST_START=0 QUARANTINE_AFTER=3 TEST_FAILOVER_INTERVAL=1 run_restart_manager "$root"
    wait_for_file "$root/active"
    [ "$(cat "$root/bad/.strikes/a.conf" 2>/dev/null)" = 2 ] \
        || fail "a successful startup probe alone must not clear historical strikes"

    attempts=0
    while [ -f "$root/bad/.strikes/a.conf" ] && [ "$attempts" -lt 50 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
    [ ! -f "$root/bad/.strikes/a.conf" ] \
        || fail "strikes should clear after FAILOVER_FAILURES stable monitoring checks"

    stop_manager
    echo "PASS: existing strikes clear only after stable health"
}

test_missing_wg_directory_is_created
test_empty_config_directory_waits_for_config
test_copy_failure_does_not_quarantine_config
test_transient_initial_health_failure_is_retried
test_fastest_config_is_selected
test_dead_tunnel_is_restarted_not_quarantined
test_startup_probes_wait_longer_than_monitoring
test_only_config_is_never_quarantined
test_unrecoverable_config_is_replaced_after_restarts
test_failed_health_check_is_quarantined_only_after_repeated_strikes
test_ranking_stops_after_budget_once_a_config_works
test_fast_start_uses_last_working_config
test_fast_start_falls_back_to_ranking
test_tunnel_is_brought_up_inside_kill_switch_window
test_tunnel_is_not_started_when_kill_switch_cannot_be_armed
test_tunnel_is_torn_down_when_kill_switch_cannot_be_finalized
test_all_awg_start_failures_preserve_every_config_and_strike
test_all_health_failures_preserve_existing_strikes
test_pending_strike_commits_only_after_replacement_is_active
test_existing_strikes_clear_only_after_stable_health
test_tun_device_is_created
echo "All failover manager tests passed"
