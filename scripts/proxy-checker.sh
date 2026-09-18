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

mkdir -p "$BAD_DIR"

# Collect configs
CONFIGS=$(ls "$CONFIG_DIR"/*.conf 2>/dev/null | grep -v "/wg0.conf$" | sort -V)

if [ -z "$CONFIGS" ]; then
    echo "ERROR: No .conf files found in $CONFIG_DIR"
    exit 2
fi

TOTAL=0
WORKING=0
FAILED=0
RESULTS=""

for config_file in $CONFIGS; do
    TOTAL=$((TOTAL + 1))
    BASENAME=$(basename "$config_file")
    WG_CONF="/etc/amnezia/amneziawg/wg0.conf"

    printf "Checking %-30s ... " "$BASENAME"

    # Copy config
    cp "$config_file" "$WG_CONF"

    # Bring up tunnel
    START=$(date +%s%N)
    awg-quick up wg0 > /dev/null 2>&1
    AWG_STATUS=$?
    END=$(date +%s%N)
    TUNNEL_MS=$(( (END - START) / 1000000 ))

    if [ "$AWG_STATUS" -ne 0 ]; then
        echo "BAD  [awg-quick failed, ${TUNNEL_MS}ms]"
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
    GEO=$(curl --interface wg0 --silent --max-time 10 "https://ipwho.is/" 2>/dev/null)
    PUBLIC_IP=$(echo "$GEO" | grep -o '"ip":"[^"]*"' | head -1 | cut -d'"' -f4)
    COUNTRY=$(echo "$GEO" | grep -o '"country":"[^"]*"' | head -1 | cut -d'"' -f4)
    CITY=$(echo "$GEO" | grep -o '"city":"[^"]*"' | head -1 | cut -d'"' -f4)
    ASN=$(echo "$GEO" | grep -o '"asn":"[^"]*"' | head -1 | cut -d'"' -f4)
    ORG=$(echo "$GEO" | grep -o '"org":"[^"]*"' | head -1 | cut -d'"' -f4)

    # Fallback if ipwho.is fails
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP=$(curl --interface wg0 --silent --max-time 10 "https://api.ipify.org?format=json" 2>/dev/null | grep -o '"ip":"[^"]*"' | cut -d'"' -f4)
        COUNTRY="N/A"
        CITY="N/A"
        ASN="N/A"
        ORG="N/A"
    fi

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
echo "$RESULTS" | while IFS= read -r line; do
    [ -n "$line" ] && printf "%s\n" "$line"
done
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
