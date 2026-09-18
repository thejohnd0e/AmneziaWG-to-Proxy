#!/bin/sh
# check-tunnel.sh — Shared tunnel health check
# Exit 0 if any HTTPS probe succeeds via wg0, exit 1 if all fail.
# Used by both failover-manager.sh and proxy-checker.sh.

TIMEOUT="${FAILOVER_TIMEOUT:-8}"
URLS="${HEALTH_URLS:-https://connectivitycheck.gstatic.com/generate_204,https://cp.cloudflare.com/generate_204}"

IFS=','

for url in $URLS; do
    url=$(echo "$url" | xargs)
    if curl --interface wg0 --fail --silent --max-time "$TIMEOUT" "$url" > /dev/null 2>&1; then
        exit 0
    fi
done

exit 1
