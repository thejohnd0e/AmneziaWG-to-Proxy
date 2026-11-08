#!/bin/sh

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$TEST_DIR")
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/curl" <<'EOF'
#!/bin/sh
eval "url=\${$#}"
printf '%s\n' "$url" >> "$PROBE_CALLS"
if [ "$url" = "$HEALTH_URL_OK" ]; then
    printf '%s' "${HEALTH_CODE:-204}"
    exit 0
fi
printf '000'
exit 7
EOF
cat > "$TMP_ROOT/bin/awg" <<'EOF'
#!/bin/sh
echo called >> "$AWG_CALLS"
EOF
chmod +x "$TMP_ROOT/bin/curl" "$TMP_ROOT/bin/awg"

export PATH="$TMP_ROOT/bin:$PATH"
export PROBE_CALLS="$TMP_ROOT/probes"
export AWG_CALLS="$TMP_ROOT/awg-calls"
export HEALTH_URL_OK='https://second.example/health'
export HEALTH_URLS='https://first.example/health, https://second.example/health'

if FAILOVER_TIMEOUT=1 sh "$PROJECT_DIR/scripts/check-tunnel.sh"; then
    :
else
    echo "FAIL: second healthy endpoint should make the check succeed" >&2
    exit 1
fi

expected=$(printf '%s\n' 'https://first.example/health' 'https://second.example/health')
[ "$(cat "$PROBE_CALLS")" = "$expected" ] \
    || { echo "FAIL: comma-separated endpoint parsing changed" >&2; exit 1; }
[ ! -e "$AWG_CALLS" ] || { echo "FAIL: diagnostics ran after a successful probe" >&2; exit 1; }

export HEALTH_URLS='https://second.example/health'
if HEALTH_CODE=302 FAILOVER_TIMEOUT=1 sh "$PROJECT_DIR/scripts/check-tunnel.sh" 2>/dev/null; then
    echo "FAIL: a redirect must not count as a healthy tunnel" >&2
    exit 1
fi
if HEALTH_CODE=503 FAILOVER_TIMEOUT=1 sh "$PROJECT_DIR/scripts/check-tunnel.sh" 2>/dev/null; then
    echo "FAIL: an error status must not count as a healthy tunnel" >&2
    exit 1
fi
HEALTH_CODE=200 FAILOVER_TIMEOUT=1 sh "$PROJECT_DIR/scripts/check-tunnel.sh"     || { echo "FAIL: a 200 answer must count as healthy" >&2; exit 1; }

echo "PASS: check-tunnel probes comma-separated endpoints, needs a 2xx answer and exits on success"
