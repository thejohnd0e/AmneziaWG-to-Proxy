#!/bin/sh

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$TEST_DIR")
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/bin"
# Answers per proxy: SOCKS_CODE / HTTP_CODE, logged as "proxy url".
cat > "$TMP_ROOT/bin/curl" <<'EOF'
#!/bin/sh
proxy=""
while [ "$#" -gt 1 ]; do
    case "$1" in
        --proxy) proxy="$2"; shift ;;
    esac
    shift
done
printf '%s %s\n' "$proxy" "$1" >> "$CURL_CALLS"
case "$proxy" in
    socks5h://*) printf '%s' "$SOCKS_CODE" ;;
    http://*) printf '%s' "$HTTP_CODE" ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/curl"

export PATH="$TMP_ROOT/bin:$PATH"
export CURL_CALLS="$TMP_ROOT/calls"
export ACTIVE_MARKER="$TMP_ROOT/active"
export HEALTH_URLS='https://a.example/204, https://b.example/204'
HC="$PROJECT_DIR/scripts/healthcheck.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

if SOCKS_CODE=204 HTTP_CODE=204 sh "$HC" 2>/dev/null; then
    fail "healthy without an active config"
fi
[ ! -e "$CURL_CALLS" ] || fail "probes ran without an active config"

echo /configs/a.conf > "$ACTIVE_MARKER"
SOCKS_CODE=204 HTTP_CODE=204 sh "$HC" || fail "both proxies answer but check failed"
[ "$(wc -l < "$CURL_CALLS")" -eq 2 ] || fail "one probe per proxy expected on success"
grep -q '^socks5h://127.0.0.1:1080 https://a.example/204$' "$CURL_CALLS" || fail "SOCKS5 proxy not probed"
grep -q '^http://127.0.0.1:8080 https://a.example/204$' "$CURL_CALLS" || fail "HTTP proxy not probed"

if SOCKS_CODE=000 HTTP_CODE=204 sh "$HC" 2>/dev/null; then
    fail "a dead SOCKS5 proxy must be unhealthy"
fi
if SOCKS_CODE=204 HTTP_CODE=000 sh "$HC" 2>/dev/null; then
    fail "a dead HTTP proxy must be unhealthy"
fi
if SOCKS_CODE=302 HTTP_CODE=302 sh "$HC" 2>/dev/null; then
    fail "redirects must not count as healthy"
fi

: > "$CURL_CALLS"
if SOCKS_CODE=000 HTTP_CODE=000 sh "$HC" 2>/dev/null; then
    fail "both proxies dead must be unhealthy"
fi
[ "$(wc -l < "$CURL_CALLS")" -eq 4 ] || fail "every health URL should be tried before giving up"

echo "PASS: healthcheck needs an active config and a 2xx answer through both proxies"
