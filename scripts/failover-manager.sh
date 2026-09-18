#!/bin/sh
# failover-manager.sh — Background failover supervisor
# Runs inside the container. Manages config selection, health monitoring,
# and automatic switching to next config on failure.

CONFIG_DIR="/configs"
BAD_DIR="/bad_config"
ACTIVE_MARKER="/tmp/active_config"
FAILURE_FILE="/tmp/failure_count"
WG_CONF="/etc/amnezia/amneziawg/wg0.conf"

INTERVAL="${FAILOVER_INTERVAL:-15}"
FAIL_THRESHOLD="${FAILOVER_FAILURES:-3}"
# --- Helpers ---

log() {
    echo "--- [failover] $(date '+%Y-%m-%d %H:%M:%S') $1 ---"
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

# --- Select next config ---

select_config() {
    local configs=$(get_configs)
    if [ -z "$configs" ]; then
        log "No .conf files found in $CONFIG_DIR"
        return 1
    fi
    echo "$configs" | head -1
}

# --- Bring up tunnel with a config ---

start_tunnel() {
    local config_file="$1"
    cp "$config_file" "$WG_CONF"
    awg-quick up wg0 > /dev/null 2>&1
    return $?
}

# --- Main ---

mkdir -p "$BAD_DIR"
echo "0" > "$FAILURE_FILE"

log "Failover manager started"
log "Config dir: $CONFIG_DIR | Bad dir: $BAD_DIR"
log "Interval: ${INTERVAL}s | Failure threshold: $FAIL_THRESHOLD"

CURRENT_CONFIG=""

while true; do
    # No active config — find one
    if [ -z "$CURRENT_CONFIG" ]; then
        CURRENT_CONFIG=$(select_config)
        if [ $? -ne 0 ] || [ -z "$CURRENT_CONFIG" ]; then
            log "Waiting for .conf files in $CONFIG_DIR..."
            sleep 30
            continue
        fi

        log "Trying config: $(basename "$CURRENT_CONFIG")"
        start_tunnel "$CURRENT_CONFIG"
        if [ $? -ne 0 ]; then
            log "awg-quick failed for $(basename "$CURRENT_CONFIG")"
            move_to_bad "$CURRENT_CONFIG"
            CURRENT_CONFIG=""
            continue
        fi

        # Initial health check
        /check-tunnel.sh
        if [ $? -ne 0 ]; then
            log "Initial health check failed for $(basename "$CURRENT_CONFIG")"
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

    /check-tunnel.sh
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
