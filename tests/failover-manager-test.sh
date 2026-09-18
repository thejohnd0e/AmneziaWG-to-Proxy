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

make_success_commands() {
    command_dir="$1"
    mkdir -p "$command_dir"

    printf '%s\n' '#!/bin/sh' 'exit 0' > "$command_dir/awg-quick"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$command_dir/check-tunnel"
    chmod +x "$command_dir/awg-quick" "$command_dir/check-tunnel"
}

test_missing_wg_directory_is_created() {
    root="$TMP_ROOT/create-directory"
    mkdir -p "$root/configs" "$root/bad"
    printf '%s\n' '[Interface]' 'PrivateKey = test' > "$root/configs/working.conf"
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

    attempts=0
    while [ ! -f "$root/active" ] && [ "$attempts" -lt 50 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done

    assert_file_exists "$root/active"
    assert_file_exists "$root/missing/amneziawg/wg0.conf"
    assert_file_exists "$root/configs/working.conf"
    assert_no_configs "$root/bad"

    kill "$MANAGER_PID"
    wait "$MANAGER_PID" 2>/dev/null || true
    MANAGER_PID=""
    echo "PASS: missing WireGuard directory is created"
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
test_copy_failure_does_not_quarantine_config
test_tun_device_is_created
echo "All failover manager tests passed"
