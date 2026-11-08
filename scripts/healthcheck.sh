#!/bin/sh
# shellcheck disable=SC3043 # Alpine's supported BusyBox ash and the test dash provide function-local variables.
# healthcheck.sh — Docker healthcheck
# Healthy only when a config is active and a request succeeds through both the
# SOCKS5 and the HTTP proxy, so a crashed proxy is reported, not only a dead wg0.

ACTIVE_MARKER="${ACTIVE_MARKER:-/tmp/active_config}"
TIMEOUT="${FAILOVER_TIMEOUT:-8}"
URLS="${HEALTH_URLS:-https://connectivitycheck.gstatic.com/generate_204,https://cp.cloudflare.com/generate_204}"
SOCKS_PROXY="${HEALTH_SOCKS_PROXY:-socks5h://127.0.0.1:1080}"
HTTP_PROXY_URL="${HEALTH_HTTP_PROXY:-http://127.0.0.1:8080}"

if [ ! -f "$ACTIVE_MARKER" ]; then
    echo "unhealthy: no active config" >&2
    exit 1
fi

# One probe per proxy is enough when it answers 2xx; redirects do not count.
probe() {
    local proxy="$1" url code
    OLD_IFS=$IFS
    IFS=','
    for url in $URLS; do
        IFS=$OLD_IFS
        url=$(printf '%s' "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$url" ] || continue
        code=$(curl --proxy "$proxy" --silent --output /dev/null --max-time "$TIMEOUT" \
            --write-out '%{http_code}' "$url" 2>/dev/null)
        case "$code" in
            2??) return 0 ;;
        esac
        IFS=','
    done
    IFS=$OLD_IFS
    return 1
}

status=0
if ! probe "$SOCKS_PROXY"; then
    echo "unhealthy: no answer through the SOCKS5 proxy" >&2
    status=1
fi
if ! probe "$HTTP_PROXY_URL"; then
    echo "unhealthy: no answer through the HTTP proxy" >&2
    status=1
fi
exit "$status"
