#!/bin/sh
# proxy-checker.sh — Manual config checker
# Run inside an isolated Docker container to test AmneziaWG configs.
# Usage: proxy-checker.sh <config_dir> [--bad-dir <bad_config_dir>]
#
# Exit codes: 0 all configs work, 1 at least one config failed, 2 usage/setup error.

CONFIG_DIR="${1:-}"
BAD_DIR="/bad_config"
TIMEOUT="${FAILOVER_TIMEOUT:-8}"
AWG_UP_TIMEOUT="${AWG_UP_TIMEOUT:-30}"
HEALTH_URLS="${HEALTH_URLS:-https://connectivitycheck.gstatic.com/generate_204,https://cp.cloudflare.com/generate_204}"
LATENCY_URL="${SPEED_TEST_URL:-${HEALTH_URLS%%,*}}"
WG_CONF="${WG_CONF:-/etc/amnezia/amneziawg/wg0.conf}"
CHECK_TUNNEL="${CHECK_TUNNEL:-/check-tunnel.sh}"
TUN_SETUP="${TUN_SETUP:-/ensure-tun.sh}"
AWG_LOG="${AWG_LOG:-/tmp/awg-quick.log}"
HEALTH_LOG="${HEALTH_LOG:-/tmp/checker-health.log}"
GEOIP="${GEOIP:-1}"

# Color output: auto (default) enables it only on a TTY, so logs and cron
# stay clean. Override with CHECKER_COLOR=always|never or NO_COLOR.
use_color=0
if [ "${CHECKER_COLOR:-auto}" = "always" ]; then
    use_color=1
elif [ "${CHECKER_COLOR:-auto}" = "never" ] || [ -n "${NO_COLOR:-}" ]; then
    use_color=0
elif [ -t 1 ]; then
    use_color=1
fi

if [ "$use_color" -eq 1 ]; then
    C_RESET=$(printf '\033[0m')
    C_BOLD=$(printf '\033[1m')
    C_DIM=$(printf '\033[2m')
    C_RED=$(printf '\033[31m')
    C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m')
    C_MAGENTA=$(printf '\033[35m')
    C_CYAN=$(printf '\033[36m')
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_MAGENTA=""
    C_CYAN=""
fi

usage() {
    echo "Usage: proxy-checker <config_dir> [--bad-dir <bad_config_dir>]"
}

case "${2:-}" in
    '') ;;
    --bad-dir)
        [ -n "${3:-}" ] || { echo "${C_RED}ERROR:${C_RESET} --bad-dir needs a directory"; usage; exit 2; }
        BAD_DIR="$3"
        ;;
    *)
        echo "${C_RED}ERROR:${C_RESET} Unknown argument: $2"
        usage
        exit 2
        ;;
esac

if [ -z "$CONFIG_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then
    echo "${C_RED}ERROR:${C_RESET} Directory not found: $CONFIG_DIR"
    usage
    exit 2
fi

if ! mkdir -p "$BAD_DIR" "$(dirname "$WG_CONF")"; then
    echo "${C_RED}ERROR:${C_RESET} Could not create required configuration directories"
    exit 2
fi

for tool in awg-quick timeout curl; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "${C_RED}ERROR:${C_RESET} $tool is not installed"
        exit 2
    fi
done

if ! "$TUN_SETUP"; then
    echo "${C_RED}ERROR:${C_RESET} TUN device setup failed"
    exit 2
fi

cleanup() {
    awg-quick down wg0 > /dev/null 2>&1
    rm -f "$AWG_LOG" "$HEALTH_LOG"
}
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Same selection as the failover manager: *.conf without wg0.conf, natural order,
# one path per line so names with spaces survive.
list_configs() {
    for config in "$CONFIG_DIR"/*.conf; do
        [ -f "$config" ] || continue
        [ "$(basename "$config")" != wg0.conf ] || continue
        printf '%s\n' "$config"
    done | sort -V
}

CONFIGS=$(list_configs)
if [ -z "$CONFIGS" ]; then
    echo "${C_RED}ERROR:${C_RESET} No .conf files found in $CONFIG_DIR"
    exit 2
fi

# Same rule as the failover manager: only full-tunnel configs are supported.
has_full_tunnel_route() {
    awk '
        {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            if (line !~ /^[[:space:]]*AllowedIPs[[:space:]]*=/) next
            sub(/^[^=]*=/, "", line)
            count = split(line, fields, ",")
            for (i = 1; i <= count; i++) {
                gsub(/[[:space:]]/, "", fields[i])
                if (fields[i] == "0.0.0.0/0") found = 1
            }
        }
        END { exit found ? 0 : 1 }
    ' "$1"
}

# Move a failed config to BAD_DIR without overwriting an older file of that name.
# Prints the new name; the source is removed only after a successful copy.
move_to_bad() {
    src="$1"
    base=$(basename "$src")
    dest="$BAD_DIR/$base"
    if [ -e "$dest" ]; then
        dest="$BAD_DIR/${base%.conf}.$(date '+%Y%m%d-%H%M%S').conf"
    fi
    if cp "$src" "$dest" && rm -f "$src"; then
        basename "$dest"
        return 0
    fi
    rm -f "$dest"
    return 1
}

# Milliseconds from a monotonic clock: BusyBox date has no %N, /proc/uptime has 10 ms steps.
now_ms() {
    if [ -r /proc/uptime ]; then
        awk '{ printf "%d\n", $1 * 1000 }' /proc/uptime
    else
        echo "$(($(date +%s) * 1000))"
    fi
}

# Median of 3 latency probes in ms; empty when no probe succeeded.
measure_latency() {
    samples=""
    count=0
    for _ in 1 2 3; do
        t=$(curl --interface wg0 --silent --max-time "$TIMEOUT" -o /dev/null \
            -w '%{http_code} %{time_total}' "$LATENCY_URL" 2>/dev/null)
        case "$t" in
            2??\ *)
                samples="${samples}${t#* }
"
                count=$((count + 1))
                ;;
        esac
    done
    [ "$count" -gt 0 ] || return 0
    printf '%s' "$samples" | sort -n | sed -n "$(((count + 1) / 2))p" \
        | awk '{ printf "%.0f", $1 * 1000 }'
}

json_str() {
    printf '%s' "$1" | tr -d '\n' \
        | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 | sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
}
json_num() {
    printf '%s' "$1" | tr -d '\n' \
        | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" \
        | head -1 | sed 's/^[^:]*:[[:space:]]*//'
}

# Public IP and GeoIP of the tunnel exit; every provider is queried over HTTPS through wg0.
lookup_geo() {
    PUBLIC_IP=""; COUNTRY=""; CITY=""; ASN=""; ORG=""
    [ "$GEOIP" = 1 ] || return 0
    geo=$(curl -4 --interface wg0 --silent --max-time 10 "https://ipwho.is/" 2>/dev/null)
    PUBLIC_IP=$(json_str "$geo" ip)
    COUNTRY=$(json_str "$geo" country)
    CITY=$(json_str "$geo" city)
    asn_num=$(json_num "$geo" asn)
    [ -z "$asn_num" ] || ASN="AS${asn_num}"
    ORG=$(json_str "$geo" org)

    if [ -z "$PUBLIC_IP" ]; then
        geo=$(curl -4 --interface wg0 --silent --max-time 10 "https://ipinfo.io/json" 2>/dev/null)
        PUBLIC_IP=$(json_str "$geo" ip)
        COUNTRY=$(json_str "$geo" country)
        CITY=$(json_str "$geo" city)
        ORG=$(json_str "$geo" org)
        case "$ORG" in AS[0-9]*) ASN=${ORG%% *}; ORG=${ORG#* } ;; esac
    fi

    if [ -z "$PUBLIC_IP" ]; then
        geo=$(curl -4 --interface wg0 --silent --max-time 10 "https://api.ipify.org?format=json" 2>/dev/null)
        PUBLIC_IP=$(json_str "$geo" ip)
    fi
}

TOTAL=0
WORKING=0
FAILED=0
SKIPPED=0
MOVED=""
# Working rows are prefixed with the latency (ms) so the summary can sort them.
OK_RESULTS=""
BAD_RESULTS=""

TAB=$(printf '\t')

record_bad() {
    # $1 basename, $2 reason, $3 tunnel ms
    BAD_RESULTS="${BAD_RESULTS}${1}${TAB}${C_RED}BAD${C_RESET}${TAB}${2}${TAB}-${TAB}-${TAB}-${TAB}-${TAB}${3}ms
"
}

fail_config() {
    # $1 path, $2 reason, $3 tunnel ms
    awg-quick down wg0 > /dev/null 2>&1
    record_bad "$(basename "$1")" "$2" "$3"
    FAILED=$((FAILED + 1))
    if moved=$(move_to_bad "$1"); then
        MOVED="${MOVED}${moved}
"
    else
        echo "  ${C_RED}ERROR:${C_RESET} could not move $(basename "$1") to $BAD_DIR; it stays in place" >&2
    fi
}

while IFS= read -r config_file; do
    [ -n "$config_file" ] || continue
    TOTAL=$((TOTAL + 1))
    BASENAME=$(basename "$config_file")
    printf "Checking %-30s ... " "$BASENAME"

    if ! has_full_tunnel_route "$config_file"; then
        printf '%sSKIP%s [no 0.0.0.0/0 in AllowedIPs: split tunnel is not supported, left in place]\n' \
            "$C_YELLOW" "$C_RESET"
        BAD_RESULTS="${BAD_RESULTS}${BASENAME}${TAB}${C_YELLOW}SKIP${C_RESET}${TAB}split tunnel${TAB}-${TAB}-${TAB}-${TAB}-${TAB}-
"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if ! cp "$config_file" "$WG_CONF" \
        || ! sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF" \
        || ! chmod 600 "$WG_CONF"; then
        echo "${C_RED}ERROR:${C_RESET} Could not stage $BASENAME at $WG_CONF"
        exit 2
    fi

    START=$(now_ms)
    timeout "$AWG_UP_TIMEOUT" awg-quick up wg0 > "$AWG_LOG" 2>&1
    AWG_STATUS=$?
    TUNNEL_MS=$(($(now_ms) - START))

    if [ "$AWG_STATUS" -ne 0 ]; then
        reason="awg-quick failed"
        [ "$AWG_STATUS" -ne 124 ] || reason="awg-quick timed out after ${AWG_UP_TIMEOUT}s"
        printf '%sBAD%s  [%s, %sms]\n' "$C_RED" "$C_RESET" "$reason" "$TUNNEL_MS"
        sed 's/^/  [awg-quick] /' "$AWG_LOG" >&2
        fail_config "$config_file" "$reason" "$TUNNEL_MS"
        continue
    fi

    if ! FAILOVER_TIMEOUT="$TIMEOUT" HEALTH_URLS="$HEALTH_URLS" "$CHECK_TUNNEL" 2> "$HEALTH_LOG"; then
        printf '%sBAD%s  [tunnel up but no connectivity, %sms]\n' "$C_RED" "$C_RESET" "$TUNNEL_MS"
        sed 's/^/  /' "$HEALTH_LOG" >&2
        fail_config "$config_file" "no connectivity" "$TUNNEL_MS"
        continue
    fi

    lookup_geo
    [ -n "$PUBLIC_IP" ] || PUBLIC_IP="N/A"
    [ -n "$COUNTRY" ] || COUNTRY="N/A"
    [ -n "$CITY" ] || CITY="N/A"
    [ -n "$ASN" ] || ASN="N/A"
    [ -n "$ORG" ] || ORG="N/A"

    LATENCY_MS=$(measure_latency)
    SORT_MS=${LATENCY_MS:-999999}
    [ -n "$LATENCY_MS" ] || LATENCY_MS="?"

    printf '%sOK%s   [%sms | %s | %s%s%s, %s%s%s | %s]\n' \
        "$C_GREEN" "$C_RESET" "$LATENCY_MS" "$PUBLIC_IP" \
        "$C_MAGENTA" "$COUNTRY" "$C_RESET" \
        "$C_CYAN" "$CITY" "$C_RESET" \
        "$ASN"
    OK_RESULTS="${OK_RESULTS}${SORT_MS}${TAB}${BASENAME}${TAB}${C_GREEN}OK${C_RESET}${TAB}${PUBLIC_IP}${TAB}${C_MAGENTA}${COUNTRY}${C_RESET}${TAB}${C_CYAN}${CITY}${C_RESET}${TAB}${ASN}${TAB}${ORG}${TAB}${LATENCY_MS}ms
"

    awg-quick down wg0 > /dev/null 2>&1
    WORKING=$((WORKING + 1))
    sleep "${CHECKER_PAUSE:-1}"
done <<EOF
$CONFIGS
EOF

rm -f "$AWG_LOG" "$HEALTH_LOG"

# Summary
echo ""
printf '%s%s%s\n' "$C_CYAN" "========================================" "$C_RESET"
printf '%s RESULTS%s\n' "$C_BOLD" "$C_RESET"
printf '%s%s%s\n' "$C_CYAN" "========================================" "$C_RESET"
printf '%sCONFIG\t\tSTATUS\tIP\t\tCOUNTRY\tCITY\tASN\tORG\tLATENCY%s\n' "$C_BOLD" "$C_RESET"
# Working configs sorted by latency (best first), then rejected ones.
printf '%s' "$OK_RESULTS" | sort -n | cut -f2-
printf '%s' "$BAD_RESULTS"
echo ""
summary="Checked: $TOTAL | ${C_GREEN}Working: $WORKING${C_RESET} | "
if [ "$FAILED" -gt 0 ]; then
    summary="${summary}${C_RED}Failed: $FAILED${C_RESET}"
else
    summary="${summary}Failed: 0"
fi
[ "$SKIPPED" -eq 0 ] || summary="${summary} | ${C_YELLOW}Skipped: $SKIPPED${C_RESET}"
printf '%s\n\n' "$summary"

if [ -n "$MOVED" ]; then
    printf '%sMoved to bad_config:%s\n' "$C_YELLOW" "$C_RESET"
    printf '%s' "$MOVED" | while IFS= read -r name; do
        printf '  %s%s%s\n' "$C_RED" "$name" "$C_RESET"
    done
    echo ""
    printf '%sTip: restore a config by moving it back to %s%s\n' "$C_DIM" "${CHECKER_HOST_CONFIG_DIR:-$CONFIG_DIR}" "$C_RESET"
fi

[ "$FAILED" -eq 0 ] || exit 1
exit 0
