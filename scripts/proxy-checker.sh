#!/bin/sh
# proxy-checker.sh — Manual config checker
# Run inside an isolated Docker container to test AmneziaWG configs.
# Usage: ./proxy-checker.sh /path/to/config [--bad-dir /path/to/bad_config]

CONFIG_DIR="$1"
BAD_DIR="${3:-../bad_config}"
TIMEOUT="${FAILOVER_TIMEOUT:-8}"
HEALTH_URL="${HEALTH_URLS%%,*}"

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
    C_CYAN=$(printf '\033[36m')
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
fi

if [ -z "$CONFIG_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then
    echo "${C_RED}ERROR:${C_RESET} Directory not found: $CONFIG_DIR"
    echo "Usage: ./proxy-checker /path/to/config [--bad-dir /path/to/bad_config]"
    exit 2
fi

WG_CONF="/etc/amnezia/amneziawg/wg0.conf"

if ! mkdir -p "$BAD_DIR" "$(dirname "$WG_CONF")"; then
    echo "${C_RED}ERROR:${C_RESET} Could not create required configuration directories"
    exit 2
fi

if ! command -v awg-quick > /dev/null 2>&1; then
    echo "${C_RED}ERROR:${C_RESET} awg-quick is not installed"
    exit 2
fi

if ! /ensure-tun.sh; then
    echo "${C_RED}ERROR:${C_RESET} TUN device setup failed"
    exit 2
fi

# Collect configs
CONFIGS=$(ls "$CONFIG_DIR"/*.conf 2>/dev/null | grep -v "/wg0.conf$" | sort -V)

if [ -z "$CONFIGS" ]; then
    echo "${C_RED}ERROR:${C_RESET} No .conf files found in $CONFIG_DIR"
    exit 2
fi

# Extract a string or numeric JSON field, tolerating whitespace after the colon.
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

TOTAL=0
WORKING=0
FAILED=0
RESULTS=""

for config_file in $CONFIGS; do
    TOTAL=$((TOTAL + 1))
    BASENAME=$(basename "$config_file")
    printf "Checking %-30s ... " "$BASENAME"

    # Copy config
    if ! cp "$config_file" "$WG_CONF"; then
        echo "${C_RED}ERROR:${C_RESET} Could not stage $BASENAME at $WG_CONF"
        exit 2
    fi
    if ! sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF" \
        || ! chmod 600 "$WG_CONF"; then
        echo "${C_RED}ERROR:${C_RESET} Could not prepare $BASENAME at $WG_CONF"
        exit 2
    fi

    # Bring up tunnel
    START=$(date +%s%N)
    AWG_LOG="/tmp/awg-quick.log"
    awg-quick up wg0 > "$AWG_LOG" 2>&1
    AWG_STATUS=$?
    END=$(date +%s%N)
    TUNNEL_MS=$(( (END - START) / 1000000 ))

    if [ "$AWG_STATUS" -ne 0 ]; then
        printf '%sBAD%s  [awg-quick failed, %sms]\n' "$C_RED" "$C_RESET" "$TUNNEL_MS"
        sed 's/^/  [awg-quick] /' "$AWG_LOG" >&2
        RESULTS="${RESULTS}${BASENAME}\t${C_RED}BAD${C_RESET}\tawg-quick failed\t-\t-\t-\t-\t${TUNNEL_MS}ms\n"
        awg-quick down wg0 > /dev/null 2>&1
        cp "$config_file" "$BAD_DIR/$(basename "$config_file")"
        rm -f "$config_file"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Health check
    HEALTH_OK=0
    OLDIFS="$IFS"
    IFS=','
    for url in $HEALTH_URLS; do
        url=$(echo "$url" | xargs)
        if curl --interface wg0 --fail --silent --max-time "$TIMEOUT" "$url" > /dev/null 2>&1; then
            HEALTH_OK=1
            break
        fi
    done
    IFS="$OLDIFS"

    if [ "$HEALTH_OK" -eq 0 ]; then
        printf '%sBAD%s  [tunnel up but no connectivity, %sms]\n' "$C_RED" "$C_RESET" "$TUNNEL_MS"
        RESULTS="${RESULTS}${BASENAME}\t${C_RED}BAD${C_RESET}\tno connectivity\t-\t-\t-\t-\t${TUNNEL_MS}ms\n"
        awg-quick down wg0 > /dev/null 2>&1
        cp "$config_file" "$BAD_DIR/$(basename "$config_file")"
        rm -f "$config_file"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Get public IP and GeoIP info
    # The checker runs without the production proxy; the active wg0 tunnel
    # provides the egress path for these requests.
    GEO=$(curl -4 --interface wg0 --silent --max-time 10 "https://ipwho.is/" 2>/dev/null)
    PUBLIC_IP=$(json_str "$GEO" ip)
    COUNTRY=$(json_str "$GEO" country)
    CITY=$(json_str "$GEO" city)
    ASN_NUM=$(json_num "$GEO" asn)
    [ -n "$ASN_NUM" ] && ASN="AS${ASN_NUM}"
    ORG=$(json_str "$GEO" org)

    # Fallback provider
    if [ -z "$PUBLIC_IP" ]; then
        GEO=$(curl -4 --interface wg0 --silent --max-time 10 "http://ip-api.com/json/" 2>/dev/null)
        PUBLIC_IP=$(json_str "$GEO" query)
        COUNTRY=$(json_str "$GEO" country)
        CITY=$(json_str "$GEO" city)
        ASN=$(json_str "$GEO" as)
        ORG=$(json_str "$GEO" org)
    fi

    # Last resort: IP only
    if [ -z "$PUBLIC_IP" ]; then
        IPJSON=$(curl -4 --interface wg0 --silent --max-time 10 "https://api.ipify.org?format=json" 2>/dev/null)
        PUBLIC_IP=$(json_str "$IPJSON" ip)
        COUNTRY="N/A"
        CITY="N/A"
        ASN="N/A"
        ORG="N/A"
    fi

    [ -n "$COUNTRY" ] || COUNTRY="N/A"
    [ -n "$CITY" ] || CITY="N/A"
    [ -n "$ASN" ] || ASN="N/A"
    [ -n "$ORG" ] || ORG="N/A"

    # Measure latency (3 probes, median)
    LAT1=$(curl --interface wg0 --silent --max-time "$TIMEOUT" -o /dev/null -w "%{time_total}" "https://connectivitycheck.gstatic.com/generate_204" 2>/dev/null)
    LAT2=$(curl --interface wg0 --silent --max-time "$TIMEOUT" -o /dev/null -w "%{time_total}" "https://connectivitycheck.gstatic.com/generate_204" 2>/dev/null)
    LAT3=$(curl --interface wg0 --silent --max-time "$TIMEOUT" -o /dev/null -w "%{time_total}" "https://connectivitycheck.gstatic.com/generate_204" 2>/dev/null)

    # Sort and pick median
    LATENCY=$(printf "%s\n%s\n%s\n" "$LAT1" "$LAT2" "$LAT3" | sed 's/[^0-9.]//g' | grep -v '^$' | sort -n | sed -n '2p')
    LATENCY_MS=$(echo "$LATENCY" | awk '{printf "%.0f", $1 * 1000}')

    printf '%sOK%s   [%sms | %s | %s, %s | %s]\n' \
        "$C_GREEN" "$C_RESET" "$LATENCY_MS" "$PUBLIC_IP" "$COUNTRY" "$CITY" "$ASN"
    RESULTS="${RESULTS}${BASENAME}\t${C_GREEN}OK${C_RESET}\t${PUBLIC_IP}\t${COUNTRY}\t${CITY}\t${ASN}\t${ORG}\t${LATENCY_MS}ms\n"

    awg-quick down wg0 > /dev/null 2>&1
    WORKING=$((WORKING + 1))
    sleep 1
done

# Summary
echo ""
printf '%s%s%s\n' "$C_CYAN" "========================================" "$C_RESET"
printf '%s RESULTS%s\n' "$C_BOLD" "$C_RESET"
printf '%s%s%s\n' "$C_CYAN" "========================================" "$C_RESET"
printf '%sCONFIG\t\tSTATUS\tIP\t\tCOUNTRY\tCITY\tASN\tORG\tLATENCY%s\n' "$C_BOLD" "$C_RESET"
printf '%b' "$RESULTS"
echo ""
if [ "$FAILED" -gt 0 ]; then
    printf 'Checked: %s | %sWorking: %s%s | %sFailed: %s%s\n' \
        "$TOTAL" "$C_GREEN" "$WORKING" "$C_RESET" "$C_RED" "$FAILED" "$C_RESET"
else
    printf 'Checked: %s | %sWorking: %s%s | Failed: 0\n' \
        "$TOTAL" "$C_GREEN" "$WORKING" "$C_RESET"
fi
echo ""

if [ "$FAILED" -gt 0 ]; then
    printf '%sMoved to bad_config:%s\n' "$C_YELLOW" "$C_RESET"
    ls "$BAD_DIR"/*.conf 2>/dev/null | while read f; do
        printf '  %s%s%s\n' "$C_RED" "$(basename "$f")" "$C_RESET"
    done
    echo ""
    printf '%sTip: restore a config by moving it back to %s%s\n' "$C_DIM" "$CONFIG_DIR" "$C_RESET"
fi

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
