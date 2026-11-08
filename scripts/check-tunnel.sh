#!/bin/sh
# check-tunnel.sh — Shared tunnel health check
# Exit 0 if any HTTPS probe succeeds via wg0, exit 1 if all fail.
# Used by both failover-manager.sh and proxy-checker.sh.

TIMEOUT="${FAILOVER_TIMEOUT:-8}"
URLS="${HEALTH_URLS:-https://connectivitycheck.gstatic.com/generate_204,https://cp.cloudflare.com/generate_204}"

OLD_IFS=$IFS
IFS=','
PROBE_LOG="/tmp/check-tunnel.$$.log"
CURL_LOG="${PROBE_LOG}.curl"
cleanup() {
    rm -f "$PROBE_LOG" "$CURL_LOG"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for url in $URLS; do
    url=$(echo "$url" | xargs)
    # Only a 2xx answer counts: a redirect or an error page is not connectivity.
    code=$(curl --interface wg0 --silent --show-error --output /dev/null \
        --max-time "$TIMEOUT" --write-out '%{http_code}' "$url" 2> "$CURL_LOG")
    case "$code" in
        2??)
            IFS=$OLD_IFS
            exit 0
            ;;
    esac
    printf '%s\n' "--- [health] Probe failed: $url (HTTP ${code:-none}) ---" >> "$PROBE_LOG"
    sed 's/^/--- [health] /' "$CURL_LOG" >> "$PROBE_LOG"
done
IFS=$OLD_IFS

cat "$PROBE_LOG" >&2
if command -v awg > /dev/null 2>&1; then
    awg show wg0 latest-handshakes 2>/dev/null \
        | sed 's/^/--- [health] latest-handshake: /' >&2
    awg show wg0 transfer 2>/dev/null \
        | sed 's/^/--- [health] transfer: /' >&2
fi

exit 1
