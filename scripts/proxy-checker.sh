#!/bin/sh
# proxy-checker.sh — Manual config checker
# Run inside an isolated Docker container to test AmneziaWG configs.
# Usage: ./proxy-checker.sh /path/to/config [--bad-dir /path/to/bad_config]

CONFIG_DIR="$1"
BAD_DIR="${3:-../bad_config}"
TIMEOUT="${FAILOVER_TIMEOUT:-8}"
HEALTH_URL="${HEALTH_URLS%%,*}"

if [ -z "$CONFIG_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then
    echo "ERROR: Directory not found: $CONFIG_DIR"
    echo "Usage: ./proxy-checker /path/to/config [--bad-dir /path/to/bad_config]"
    exit 2
fi

WG_CONF="/etc/amnezia/amneziawg/wg0.conf"

if ! mkdir -p "$BAD_DIR" "$(dirname "$WG_CONF")"; then
    echo "ERROR: Could not create required configuration directories"
    exit 2
fi

if ! command -v awg-quick > /dev/null 2>&1; then
    echo "ERROR: awg-quick is not installed"
    exit 2
fi

if ! /ensure-tun.sh; then
    echo "ERROR: TUN device setup failed"
    exit 2
fi

# Collect configs
CONFIGS=$(ls "$CONFIG_DIR"/*.conf 2>/dev/null | grep -v "/wg0.conf$" | sort -V)

if [ -z "$CONFIGS" ]; then
    echo "ERROR: No .conf files found in $CONFIG_DIR"
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
        echo "ERROR: Could not stage $BASENAME at $WG_CONF"
        exit 2
    fi
    if ! sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF" \
        || ! chmod 600 "$WG_CONF"; then
        echo "ERROR: Could not prepare $BASENAME at $WG_CONF"
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
        echo "BAD  [awg-quick failed, ${TUNNEL_MS}ms]"
        sed 's/^/  [awg-quick] /' "$AWG_LOG" >&2
        RESULTS="${RESULTS}${BASENAME}\tBAD\tawg-quick failed\t-\t-\t-\t-\t${TUNNEL_MS}ms\n"
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
        echo "BAD  [tunnel up but no connectivity, ${TUNNEL_MS}ms]"
        RESULTS="${RESULTS}${BASENAME}\tBAD\tno connectivity\t-\t-\t-\t-\t${TUNNEL_MS}ms\n"
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

    echo "OK   [${LATENCY_MS}ms | ${PUBLIC_IP} | ${COUNTRY}, ${CITY} | ${ASN}]"
    RESULTS="${RESULTS}${BASENAME}\tOK\t${PUBLIC_IP}\t${COUNTRY}\t${CITY}\t${ASN}\t${ORG}\t${LATENCY_MS}ms\n"

    awg-quick down wg0 > /dev/null 2>&1
    WORKING=$((WORKING + 1))
    sleep 1
done

# Summary
echo ""
echo "========================================"
echo " RESULTS"
echo "========================================"
printf "CONFIG\t\tSTATUS\tIP\t\tCOUNTRY\tCITY\tASN\tORG\tLATENCY\n"
printf '%b' "$RESULTS"
echo ""
echo "Checked: $TOTAL | Working: $WORKING | Failed: $FAILED"
echo ""

if [ "$FAILED" -gt 0 ]; then
    echo "Moved to bad_config:"
    ls "$BAD_DIR"/*.conf 2>/dev/null | while read f; do
        echo "  $(basename "$f")"
    done
    echo ""
    echo "Tip: restore a config by moving it back to $CONFIG_DIR"
fi

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
