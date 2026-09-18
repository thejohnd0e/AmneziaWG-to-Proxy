#!/bin/sh
# failover-manager.sh — Background failover supervisor
# Runs inside the container. Manages config selection, health monitoring,
# and automatic switching to next config on failure.
#
# On startup it speed-tests every config, ranks them by latency and connects
# to the fastest working one. Later failures fall through to the next ranked
# config, re-ranking only when the list is exhausted.

CONFIG_DIR="${CONFIG_DIR:-/configs}"
BAD_DIR="${BAD_DIR:-/bad_config}"
ACTIVE_MARKER="${ACTIVE_MARKER:-/tmp/active_config}"
FAILURE_FILE="${FAILURE_FILE:-/tmp/failure_count}"
WG_CONF="${WG_CONF:-/etc/amnezia/amneziawg/wg0.conf}"
CHECK_TUNNEL="${CHECK_TUNNEL:-/check-tunnel.sh}"
TUN_SETUP="${TUN_SETUP:-/ensure-tun.sh}"
AWG_LOG="${AWG_LOG:-/tmp/awg-quick.log}"

INTERVAL="${FAILOVER_INTERVAL:-15}"
FAIL_THRESHOLD="${FAILOVER_FAILURES:-3}"
CONFIG_POLL_INTERVAL="${CONFIG_POLL_INTERVAL:-30}"
HEALTH_TIMEOUT="${FAILOVER_TIMEOUT:-8}"
SPEED_TEST="${SPEED_TEST:-1}"
SPEED_TEST_URL="${SPEED_TEST_URL:-}"

# --- Helpers ---

# Logs go to stderr so command substitution only captures real data.
log() {
    echo "--- [failover] $(date '+%Y-%m-%d %H:%M:%S') $1 ---" >&2
}

get_configs() {
    ls "$CONFIG_DIR"/*.conf 2>/dev/null \
        | grep -v "/wg0.conf$" \
        | sort -V
}

# --- Move failed config to bad_config ---

move_to_bad() {
    local src="$1"
    local base=$(basename "$src")
    local dest="$BAD_DIR/$base"

    # Handle name collision
    if [ -f "$dest" ]; then
        local ts=$(date '+%Y%m%d-%H%M%S')
        dest="$BAD_DIR/${base%.conf}.${ts}.conf"
    fi

    cp "$src" "$dest"
    if [ $? -eq 0 ]; then
        rm -f "$src"
        log "Moved $base -> bad_config/$(basename "$dest")"
    else
        log "ERROR: Failed to move $base to bad_config"
    fi
}

# --- Bring up tunnel with a config ---

start_tunnel() {
    local config_file="$1"
    if ! cp "$config_file" "$WG_CONF"; then
        log "ERROR: Could not stage $(basename "$config_file") at $WG_CONF"
        return 2
    fi
    # Docker owns /etc/resolv.conf, so wg-quick must not invoke resolvconf.
    if ! sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF" \
        || ! chmod 600 "$WG_CONF"; then
        log "ERROR: Could not prepare $(basename "$config_file") at $WG_CONF"
        return 2
    fi
    if awg-quick up wg0 > "$AWG_LOG" 2>&1; then
        return 0
    fi

    log "awg-quick diagnostic output follows"
    sed 's/^/--- [awg-quick] /' "$AWG_LOG" >&2
    return 1
}

# Retry a health check up to the failure threshold before giving up.
health_check_with_retries() {
    local config="$1"
    local attempt=1

    while [ "$attempt" -le "$FAIL_THRESHOLD" ]; do
        if "$CHECK_TUNNEL"; then
            return 0
        fi
        log "Health check failed ($attempt / $FAIL_THRESHOLD) for $(basename "$config")"
        if [ "$attempt" -lt "$FAIL_THRESHOLD" ]; then
            sleep "$INTERVAL"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

# Best round-trip time in milliseconds through wg0 (empty on failure).
# DNS lookup time is subtracted so configs are ranked by server latency.
measure_latency() {
    local url="${SPEED_TEST_URL:-${HEALTH_URLS%%,*}}"
    [ -n "$url" ] || url="https://connectivitycheck.gstatic.com/generate_204"

    local samples=""
    local i=1
    local t val
    while [ "$i" -le 3 ]; do
        t=$(curl --interface wg0 --silent --max-time "$HEALTH_TIMEOUT" \
            -o /dev/null -w '%{time_namelookup} %{time_total}' "$url" 2>/dev/null)
        val=$(printf '%s\n' "$t" \
            | awk 'NF == 2 { d = $2 - $1; if (d < 0) d = 0; printf "%.6f", d }')
        case "$val" in
            ''|*[!0-9.]*) : ;;
            *) samples="${samples}${val}\n" ;;
        esac
        i=$((i + 1))
    done

    printf '%b' "$samples" | sort -n | sed -n '1p' | awk '{printf "%.0f", $1 * 1000}'
}

# Speed-test every config. Prints "latency<TAB>config" lines sorted best-first.
# Configs that cannot start or pass a health check are quarantined.
rank_configs() {
    local configs
    configs=$(get_configs)
    [ -n "$configs" ] || return 0

    local results=""
    local config status ms
    for config in $configs; do
        log "Speed test: $(basename "$config")"

        start_tunnel "$config"
        status=$?
        if [ "$status" -eq 2 ]; then
            log "Fatal staging error; leaving $(basename "$config") in $CONFIG_DIR"
            return 2
        fi
        if [ "$status" -ne 0 ]; then
            log "awg-quick failed for $(basename "$config")"
            move_to_bad "$config"
            continue
        fi

        if ! health_check_with_retries "$config"; then
            log "No connectivity for $(basename "$config")"
            awg-quick down wg0 > /dev/null 2>&1
            move_to_bad "$config"
            continue
        fi

        ms=$(measure_latency)
        log "Speed test: $(basename "$config") = ${ms:-?} ms"
        results="${results}${ms}\t${config}\n"

        awg-quick down wg0 > /dev/null 2>&1
    done

    printf '%b' "$results" | sort -n
}

# --- Main ---

if ! mkdir -p "$BAD_DIR" "$(dirname "$WG_CONF")"; then
    log "ERROR: Could not create required configuration directories"
    exit 1
fi

if ! command -v awg-quick > /dev/null 2>&1; then
    log "ERROR: awg-quick is not installed"
    exit 1
fi

if ! "$TUN_SETUP"; then
    log "ERROR: TUN device setup failed"
    exit 1
fi

echo "0" > "$FAILURE_FILE"

log "Failover manager started"
log "Config dir: $CONFIG_DIR | Bad dir: $BAD_DIR"
log "Interval: ${INTERVAL}s | Failure threshold: $FAIL_THRESHOLD | Speed test: $SPEED_TEST"

CURRENT_CONFIG=""
RANKED=""

while true; do
    # No active config — pick the fastest known one.
    if [ -z "$CURRENT_CONFIG" ]; then
        if [ -z "$RANKED" ]; then
            if [ "$SPEED_TEST" = "1" ]; then
                log "Ranking configs by latency..."
                RANKED=$(rank_configs)
                RANK_STATUS=$?
                if [ "$RANK_STATUS" -eq 2 ]; then
                    exit 1
                fi
            else
                RANKED=$(get_configs | sed 's/^/0\t/')
            fi
        fi

        if [ -z "$RANKED" ]; then
            log "No working configs found in $CONFIG_DIR"
            log "Waiting for .conf files in $CONFIG_DIR..."
            sleep "$CONFIG_POLL_INTERVAL"
            continue
        fi

        CURRENT_CONFIG=$(printf '%s\n' "$RANKED" | sed -n '1p' | cut -f2-)
        RANKED=$(printf '%s\n' "$RANKED" | sed '1d')

        log "Trying config: $(basename "$CURRENT_CONFIG")"
        start_tunnel "$CURRENT_CONFIG"
        START_STATUS=$?
        if [ "$START_STATUS" -eq 2 ]; then
            log "Fatal staging error; leaving $(basename "$CURRENT_CONFIG") in $CONFIG_DIR"
            exit 1
        fi
        if [ "$START_STATUS" -ne 0 ]; then
            log "awg-quick failed for $(basename "$CURRENT_CONFIG")"
            move_to_bad "$CURRENT_CONFIG"
            CURRENT_CONFIG=""
            continue
        fi

        if ! health_check_with_retries "$CURRENT_CONFIG"; then
            awg-quick down wg0 > /dev/null 2>&1
            move_to_bad "$CURRENT_CONFIG"
            CURRENT_CONFIG=""
            continue
        fi

        log "Config $(basename "$CURRENT_CONFIG") is ACTIVE"
        echo "$CURRENT_CONFIG" > "$ACTIVE_MARKER"
        echo "0" > "$FAILURE_FILE"
    fi

    # Monitoring loop
    sleep "$INTERVAL"

    "$CHECK_TUNNEL"
    if [ $? -eq 0 ]; then
        echo "0" > "$FAILURE_FILE"
        continue
    fi

    # Health check failed
    FAIL_COUNT=$(cat "$FAILURE_FILE")
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "$FAIL_COUNT" > "$FAILURE_FILE"
    log "Health check failed ($FAIL_COUNT / $FAIL_THRESHOLD)"

    if [ "$FAIL_COUNT" -lt "$FAIL_THRESHOLD" ]; then
        continue
    fi

    # Threshold reached — switch config
    log "Failure threshold reached. Switching config..."
    awg-quick down wg0 > /dev/null 2>&1
    move_to_bad "$CURRENT_CONFIG"
    CURRENT_CONFIG=""
    echo "0" > "$FAILURE_FILE"

    # Small pause before trying next config
    sleep 2
done
