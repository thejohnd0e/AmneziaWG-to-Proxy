#!/bin/sh

set -u

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$TEST_DIR")
MANAGER="$PROJECT_DIR/scripts/failover-manager.sh"
TUN_SETUP="$PROJECT_DIR/scripts/ensure-tun.sh"
TMP_ROOT=$(mktemp -d)
MANAGER_PID=""

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
    TUN_SETUP="$TUN_SETUP" \
    TUN_DEVICE=/dev/null \
    FAILOVER_FAILURES=3 \
    FAILOVER_INTERVAL=0.1 \
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

test_missing_wg_directory_is_created
test_empty_config_directory_waits_for_config
test_copy_failure_does_not_quarantine_config
test_transient_initial_health_failure_is_retried
test_fastest_config_is_selected
test_tun_device_is_created
echo "All failover manager tests passed"
