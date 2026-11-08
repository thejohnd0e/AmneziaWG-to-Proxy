#!/bin/sh

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$TEST_DIR")
TMP_ROOT=$(mktemp -d)
EP_PID=""
cleanup() {
    [ -z "$EP_PID" ] || kill "$EP_PID" 2>/dev/null || true
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
    echo "FAIL: $1" >&2
    [ ! -f "$TMP_ROOT/log" ] || sed 's/^/  log: /' "$TMP_ROOT/log" >&2
    exit 1
}

bin="$TMP_ROOT/bin"
mkdir -p "$bin"
export STATE="$TMP_ROOT"
export ACTIVE_MARKER="$TMP_ROOT/active"
export PRIVOXY_CONFIG="$TMP_ROOT/privoxy.conf"
printf 'listen-address [::]:8080\n' > "$PRIVOXY_CONFIG"

cat > "$bin/ok" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$bin/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$bin/awg-quick" <<'EOF'
#!/bin/sh
echo "$*" >> "$STATE/awg-calls"
EOF
# Manager: activates a config, records TERM, exits with MANAGER_STATUS when asked to.
cat > "$bin/manager" <<'EOF'
#!/bin/sh
trap 'echo term >> "$STATE/manager-term"; exit 0' TERM
echo /configs/a.conf > "$ACTIVE_MARKER"
while [ ! -f "$STATE/manager-stop" ]; do sleep 0.1; done
exit "${MANAGER_STATUS:-3}"
EOF
# The first SOCKS5 proxy dies at once; later ones stay up.
cat > "$bin/microsocks" <<'EOF'
#!/bin/sh
echo start >> "$STATE/socks-starts"
[ "$(wc -l < "$STATE/socks-starts")" -gt 1 ] || exit 1
trap 'exit 0' TERM
while :; do sleep 0.1; done
EOF
cat > "$bin/privoxy" <<'EOF'
#!/bin/sh
echo "$*" >> "$STATE/privoxy-args"
trap 'exit 0' TERM
while :; do sleep 0.1; done
EOF
chmod +x "$bin"/*

run_entrypoint() {
    PATH="$bin:$PATH" KILLSWITCH="$bin/ok" PROXY_ROUTES="$bin/ok" FAILOVER_MANAGER="$bin/manager" \
        MICROSOCKS="$bin/microsocks" WAIT_INTERVAL=0.1 SUPERVISE_INTERVAL=0.2 HTTPPORT="${1:-}" \
        sh "$PROJECT_DIR/scripts/entrypoint.sh" > "$TMP_ROOT/log" 2>&1 &
    EP_PID=$!
}

wait_for() {
    n=0
    while ! eval "$1"; do
        n=$((n + 1))
        [ "$n" -lt 100 ] || fail "$2"
        sleep 0.1
    done
}

# 1. A crashed proxy is restarted; the manager's exit status ends the container.
run_entrypoint 8118
wait_for '[ -f "$STATE/socks-starts" ] && [ "$(wc -l < "$STATE/socks-starts")" -ge 2 ]' \
    "crashed SOCKS5 proxy was not restarted"
grep -q -- '--no-daemon' "$STATE/privoxy-args" || fail "privoxy must run in the foreground to be supervised"
grep -q 'HTTPPORT=8118 is ignored' "$TMP_ROOT/log" || fail "a non-default HTTPPORT must be reported"
grep -qx 'listen-address \[::\]:8080' "$PRIVOXY_CONFIG" || fail "privoxy must keep listening on 8080"
touch "$STATE/manager-stop"
status=0
wait "$EP_PID" || status=$?
EP_PID=""
[ "$status" -eq 3 ] || fail "entrypoint must exit with the manager's status, got $status"

# 2. TERM reaches the manager and takes the tunnel down promptly.
rm -f "$STATE/manager-stop" "$STATE/socks-starts" "$STATE/awg-calls" "$ACTIVE_MARKER"
run_entrypoint
wait_for '[ -f "$STATE/privoxy-args" ] && [ -f "$STATE/socks-starts" ]' "proxies did not start"
started=$(date +%s)
kill -TERM "$EP_PID"
status=0
wait "$EP_PID" || status=$?
EP_PID=""
[ "$status" -eq 0 ] || fail "TERM must stop the entrypoint cleanly, got $status"
[ $(($(date +%s) - started)) -le 5 ] || fail "TERM took too long to handle"
[ -f "$STATE/manager-term" ] || fail "TERM was not forwarded to the failover manager"
grep -q '^down wg0$' "$STATE/awg-calls" || fail "tunnel not taken down on TERM"

echo "PASS: entrypoint restarts crashed proxies, forwards TERM and keeps HTTP on 8080"
