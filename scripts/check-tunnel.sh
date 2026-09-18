#!/bin/sh
# check-tunnel.sh — Shared tunnel health check
# Exit 0 if any HTTPS probe succeeds via wg0, exit 1 if all fail.
# Used by both failover-manager.sh and proxy-checker.sh.

TIMEOUT="${FAILOVER_TIMEOUT:-8}"
URLS="${HEALTH_URLS:-https://connectivitycheck.gstatic.com/generate_204,https://cp.cloudflare.com/generate_204}"

IFS=','
PROBE_LOG="/tmp/check-tunnel.$$.log"
CURL_LOG="${PROBE_LOG}.curl"
trap 'rm -f "$PROBE_LOG" "$CURL_LOG"' EXIT INT TERM

for url in $URLS; do
    url=$(echo "$url" | xargs)
    if curl --interface wg0 --fail --silent --show-error \
        --max-time "$TIMEOUT" "$url" > /dev/null 2> "$CURL_LOG"; then
        exit 0
    fi
    printf '%s\n' "--- [health] Probe failed: $url ---" >> "$PROBE_LOG"
    sed 's/^/--- [health] /' "$CURL_LOG" >> "$PROBE_LOG"
done

cat "$PROBE_LOG" >&2
if command -v awg > /dev/null 2>&1; then
    awg show wg0 latest-handshakes 2>/dev/null \
        | sed 's/^/--- [health] latest-handshake: /' >&2
    awg show wg0 transfer 2>/dev/null \
        | sed 's/^/--- [health] transfer: /' >&2
fi

exit 1
