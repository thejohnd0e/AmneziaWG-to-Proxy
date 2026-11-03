#!/bin/sh
# shellcheck disable=SC3043 # Alpine's supported BusyBox ash and the test dash provide function-local variables.
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
KILLSWITCH="${KILLSWITCH:-/killswitch.sh}"
RESOLVE_ENDPOINT="${RESOLVE_ENDPOINT:-/resolve-endpoint.sh}"
AWG_LOG="${AWG_LOG:-/tmp/awg-quick.log}"

INTERVAL="${FAILOVER_INTERVAL:-15}"
FAIL_THRESHOLD="${FAILOVER_FAILURES:-3}"
CONFIG_POLL_INTERVAL="${CONFIG_POLL_INTERVAL:-30}"
HEALTH_TIMEOUT="${FAILOVER_TIMEOUT:-8}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-8}"
AWG_UP_TIMEOUT="${AWG_UP_TIMEOUT:-30}"
TUNNEL_RESTARTS="${TUNNEL_RESTARTS:-2}"
QUARANTINE_AFTER="${QUARANTINE_AFTER:-3}"
RANK_BUDGET="${RANK_BUDGET:-0}"
STARTUP_CHECKS="${STARTUP_CHECKS:-1}"
STRIKE_DIR="${STRIKE_DIR:-$BAD_DIR/.strikes}"
FAST_START="${FAST_START:-1}"
LAST_ACTIVE_FILE="${LAST_ACTIVE_FILE:-$BAD_DIR/.last_active}"
PENDING_FAILURE_FILE="${PENDING_FAILURE_FILE:-/tmp/pending_failures}"
SPEED_TEST="${SPEED_TEST:-1}"
SPEED_TEST_URL="${SPEED_TEST_URL:-}"

# --- Helpers ---

# Logs go to stderr so command substitution only captures real data.
log() {
    echo "--- [failover] $(date '+%Y-%m-%d %H:%M:%S') $1 ---" >&2
}

get_configs() {
    tab=$(printf '\t')
    newline='
'
    for config in "$CONFIG_DIR"/*.conf; do
        [ -f "$config" ] || continue
        [ "$(basename "$config")" != wg0.conf ] || continue
        case "$config" in
            *"$tab"*|*"$newline"*)
                log "ERROR: Config filename contains a tab or newline; skipping"
                continue
                ;;
        esac
        printf '%s\n' "$config"
    done | sort -V
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

# A config that merely fails a health check is not quarantined at once: a network
# blip must not cost a working config. It gets a strike (kept across restarts in
# $STRIKE_DIR) and is moved to bad_config/ only after QUARANTINE_AFTER strikes.
strike_config() {
    local config="$1"
    local base=$(basename "$config")
    local n

    mkdir -p "$STRIKE_DIR"
    n=$(cat "$STRIKE_DIR/$base" 2>/dev/null || echo 0)
    n=$((n + 1))
    if [ "$n" -ge "$QUARANTINE_AFTER" ]; then
        rm -f "$STRIKE_DIR/$base"
        move_to_bad "$config"
    else
        echo "$n" > "$STRIKE_DIR/$base"
        log "$base failed ($n / $QUARANTINE_AFTER), keeping it for another try"
    fi
}

clear_strikes() {
    rm -f "$STRIKE_DIR/$(basename "$1")"
}

record_pending_failure() {
    local config="$1"
    [ -f "$config" ] || return 0
    grep -Fqx "$config" "$PENDING_FAILURE_FILE" 2>/dev/null && return 0
    printf '%s\n' "$config" >> "$PENDING_FAILURE_FILE"
}

commit_pending_failures() {
    local active="$1"
    local config
    [ -f "$PENDING_FAILURE_FILE" ] || return 0
    while IFS= read -r config; do
        [ -n "$config" ] || continue
        [ "$config" = "$active" ] && continue
        [ -f "$config" ] && strike_config "$config"
    done < "$PENDING_FAILURE_FILE"
    : > "$PENDING_FAILURE_FILE"
}

discard_pending_failures() {
    : > "$PENDING_FAILURE_FILE"
}

# --- Bring up tunnel with a config ---

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

is_ipv4_address() {
    awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++)
                if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i > 255 || ($i != "0" && substr($i, 1, 1) == "0")) exit 1
        }
    ' <<EOF
$1
EOF
}

is_ipv6_address() {
    awk '
        function groups(s, a, n, i) {
            if (s == "") return 0
            n = split(s, a, ":")
            for (i = 1; i <= n; i++)
                if (a[i] !~ /^[[:xdigit:]]+$/ || length(a[i]) > 4) return -100
            return n
        }
        {
            s = $0
            if (s !~ /^[0-9A-Fa-f:]+$/ || s ~ /:::/) exit 1
            p = index(s, "::")
            if (p) {
                left = substr(s, 1, p - 1)
                right = substr(s, p + 2)
                if (index(right, "::")) exit 1
                n = groups(left) + groups(right)
                if (n < 0 || n >= 8) exit 1
            } else if (groups(s) != 8) exit 1
            compact = s
            gsub(/:/, "", compact)
            if (compact == "" || compact ~ /^0+$/) exit 1
        }
    ' <<EOF
$1
EOF
}

valid_endpoint_hostname() {
    local host="${1%.}"
    case "$host" in
        ''|.*|*..*|*[!A-Za-z0-9.-]*) return 1 ;;
    esac
    [ "${#host}" -le 253 ] || return 1
    printf '%s\n' "$host" | awk -F. '{
        for (i = 1; i <= NF; i++)
            if (length($i) == 0 || length($i) > 63 || $i ~ /^-/ || $i ~ /-$/) exit 1
    }'
}

parse_endpoint() {
    local endpoint="$1" host port
    ENDPOINT_HOST=""
    ENDPOINT_PORT=""
    ENDPOINT_KIND=""
    case "$endpoint" in
        \[* )
            host=${endpoint#\[}
            case "$host" in
                *\]:*) ;;
                *)
                    log "ERROR: Unsupported bracketed IPv6 Endpoint syntax"
                    return 1
                    ;;
            esac
            port=${host#*\]:}
            host=${host%%\]:*}
            if ! is_ipv6_address "$host"; then
                log "ERROR: Unsupported bracketed IPv6 Endpoint syntax"
                return 1
            fi
            ENDPOINT_KIND=ipv6
            ;;
        *:*)
            host=${endpoint%:*}
            port=${endpoint##*:}
            case "$host" in *:*)
                log "ERROR: IPv6 Endpoint must be bracketed"
                return 1
                ;;
            esac
            case "$host" in
                *\[*|*\]*)
                    log "ERROR: Invalid Endpoint host syntax"
                    return 1
                    ;;
            esac
            if is_ipv4_address "$host"; then
                ENDPOINT_KIND=ipv4
            elif case "$host" in *[!0-9.]*) valid_endpoint_hostname "$host" ;; *) false ;; esac; then
                ENDPOINT_KIND=hostname
                host=${host%.}
            else
                log "ERROR: Invalid Endpoint host syntax"
                return 1
            fi
            ;;
        *)
            log "ERROR: Endpoint must include a host and port"
            return 1
            ;;
    esac
    if ! printf '%s\n' "$port" | awk '$0 !~ /^[0-9]+$/ || $0 < 1 || $0 > 65535 { exit 1 }'; then
        log "ERROR: Invalid Endpoint port"
        return 1
    fi
    ENDPOINT_HOST="$host"
    ENDPOINT_PORT="$port"
}

terminate_proxy_processes() {
    local pids
    pids=$(pidof privoxy microsocks 2>/dev/null || true)
    [ -z "$pids" ] || kill $pids 2>/dev/null || true
}

close_dns_window() {
    [ "$DNS_WINDOW_OPEN" = 1 ] || return 0
    if ! "$KILLSWITCH" apply; then
        log "FATAL: Could not close endpoint DNS permission; stopping proxies and tunnel"
        DNS_WINDOW_OPEN=0
        rm -f "$ACTIVE_MARKER"
        awg-quick down wg0 > /dev/null 2>&1 || true
        terminate_proxy_processes
        exit 1
    fi
    DNS_WINDOW_OPEN=0
}

open_dns_window() {
    command -v timeout > /dev/null 2>&1 || {
        log "ERROR: timeout is required for endpoint DNS"
        return 2
    }
    command -v su-exec > /dev/null 2>&1 || {
        log "ERROR: su-exec is required for endpoint DNS"
        return 2
    }
    [ -x "$RESOLVE_ENDPOINT" ] || {
        log "ERROR: Endpoint resolver helper is missing or not executable"
        return 2
    }
    DNS_WINDOW_OPEN=1
    if ! "$KILLSWITCH" dns-open; then
        log "ERROR: Could not open scoped endpoint DNS permission"
        if ! "$KILLSWITCH" apply; then
            log "FATAL: Could not restore kill switch after DNS setup failure"
            terminate_proxy_processes
            exit 1
        fi
        DNS_WINDOW_OPEN=0
        return 2
    fi
    return 0
}

stage_config() {
    local source="$1" stage="${WG_CONF}.stage.$$" output="${WG_CONF}.resolved.$$"
    local line value endpoint resolved status prefix leading trailing
    local dns_status=0
    rm -f "$stage" "$output"
    if ! cp "$source" "$stage" \
        || ! sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$stage" \
        || ! chmod 600 "$stage"; then
        log "ERROR: Could not stage $(basename "$source") at $WG_CONF"
        rm -f "$stage" "$output"
        return 2
    fi
    : > "$output" || {
        rm -f "$stage" "$output"
        return 2
    }

    while IFS= read -r line || [ -n "$line" ]; do
        if printf '%s\n' "$line" | grep -Eq '^[[:space:]]*Endpoint[[:space:]]*='; then
            value=${line#*=}
            leading=$(printf '%s' "$value" | sed 's/^\([[:space:]]*\).*$/\1/')
            trailing=$(printf '%s' "$value" | sed 's/^.*\([[:space:]]*\)$/\1/')
            value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if ! parse_endpoint "$value"; then
                rm -f "$stage" "$output"
                close_dns_window || return 2
                return 3
            fi
            endpoint="$ENDPOINT_HOST:$ENDPOINT_PORT"
            case "$ENDPOINT_KIND" in
                ipv4) ;;
                ipv6) endpoint="[$ENDPOINT_HOST]:$ENDPOINT_PORT" ;;
                hostname)
                    if [ "$DNS_WINDOW_OPEN" -eq 0 ]; then
                        open_dns_window
                        dns_status=$?
                        if [ "$dns_status" -ne 0 ]; then
                            rm -f "$stage" "$output"
                            return "$dns_status"
                        fi
                    fi
                    resolved=$(timeout -k 2 10 su-exec 65532:65532 "$RESOLVE_ENDPOINT" "$ENDPOINT_HOST")
                    status=$?
                    if [ "$status" -ne 0 ]; then
                        log "Endpoint DNS resolution failed for $(basename "$source")"
                        rm -f "$stage" "$output"
                        close_dns_window || return 2
                        return 4
                    fi
                    if ! is_ipv4_address "$resolved" && ! is_ipv6_address "$resolved"; then
                        log "ERROR: Resolver helper returned an invalid address"
                        rm -f "$stage" "$output"
                        close_dns_window || return 2
                        return 2
                    fi
                    if is_ipv6_address "$resolved"; then
                        endpoint="[$resolved]:$ENDPOINT_PORT"
                    else
                        endpoint="$resolved:$ENDPOINT_PORT"
                    fi
                    ;;
            esac
            prefix=${line%%=*}
            printf '%s=%s%s%s\n' "$prefix" "$leading" "$endpoint" "$trailing" >> "$output" || {
                rm -f "$stage" "$output"
                close_dns_window || return 2
                return 2
            }
        else
            printf '%s\n' "$line" >> "$output" || {
                rm -f "$stage" "$output"
                close_dns_window || return 2
                return 2
            }
        fi
    done < "$stage"
    rm -f "$stage"
    close_dns_window || {
        rm -f "$output"
        return 2
    }
    chmod 600 "$output" && mv -f "$output" "$WG_CONF" || {
        log "ERROR: Could not install resolved tunnel config"
        rm -f "$output"
        return 2
    }
}

# The kill switch stays armed whether or not wg0 exists. Hostname endpoints are
# resolved in the scoped staging window; DNS is closed before awg-quick starts.
start_tunnel() {
    local config_file="$1"
    local up_status=0
    if ! has_full_tunnel_route "$config_file"; then
        log "ERROR: $(basename "$config_file") has no 0.0.0.0/0 in AllowedIPs (split tunnel is not supported)"
        return 3
    fi
    stage_config "$config_file"
    local stage_status=$?
    [ "$stage_status" -eq 0 ] || return "$stage_status"
    if ! command -v timeout > /dev/null 2>&1; then
        log "ERROR: timeout command is required to bound awg-quick up"
        "$KILLSWITCH" apply || log "ERROR: Kill switch could not be re-applied"
        return 2
    fi
    timeout "$AWG_UP_TIMEOUT" awg-quick up wg0 > "$AWG_LOG" 2>&1 || up_status=1
    if ! "$KILLSWITCH" apply; then
        log "ERROR: Kill switch could not be finalized, taking the tunnel down"
        awg-quick down wg0 > /dev/null 2>&1
        return 2
    fi
    if [ "$up_status" -eq 0 ]; then
        return 0
    fi

    log "awg-quick diagnostic output follows"
    sed 's/^/--- [awg-quick] /' "$AWG_LOG" >&2
    return 1
}

# Retry a health check up to $2 times (default: the failure threshold). Startup, ranking and
# restart checks wait up to STARTUP_TIMEOUT per probe: the first handshake of a tunnel can be
# slow. The monitoring loop keeps the shorter FAILOVER_TIMEOUT so a stall is noticed quickly.
health_check_with_retries() {
    local config="$1"
    local max="${2:-$FAIL_THRESHOLD}"
    local attempt=1

    while [ "$attempt" -le "$max" ]; do
        if FAILOVER_TIMEOUT="$STARTUP_TIMEOUT" "$CHECK_TUNNEL"; then
            return 0
        fi
        log "Health check failed ($attempt / $max) for $(basename "$config")"
        if [ "$attempt" -lt "$max" ]; then
            sleep "$INTERVAL"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

# Bring the active tunnel down and up again on the same config. This gives
# amneziawg a fresh UDP source port, which clears a stuck NAT/conntrack mapping
# (handshakes stop getting answers while the config itself is fine).
# Returns 0 if the tunnel is healthy afterwards.
restart_tunnel() {
    local config="$1"
    rm -f "$ACTIVE_MARKER"
    awg-quick down wg0 > /dev/null 2>&1
    sleep 2
    start_tunnel "$config" || return 1
    if health_check_with_retries "$config"; then
        printf '%s\n' "$config" > "$ACTIVE_MARKER"
        return 0
    fi
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
        if t=$(curl --interface wg0 --silent --max-time "$HEALTH_TIMEOUT" \
            -o /dev/null -w '%{time_namelookup} %{time_total}' "$url" 2>/dev/null); then
            val=$(printf '%s\n' "$t" \
                | awk 'NF == 2 { d = $2 - $1; if (d < 0) d = 0; printf "%.6f", d }')
        else
            val=""
        fi
        case "$val" in
            ''|*[!0-9.]*) : ;;
            *) samples="${samples}${val}\n" ;;
        esac
        i=$((i + 1))
    done

    printf '%b' "$samples" | sort -n | sed -n '1p' | awk '{printf "%.0f", $1 * 1000}'
}

# Speed-test configs. Prints "latency<TAB>config" lines sorted best-first.
# Failed candidates are kept pending until a replacement is active. After RANK_BUDGET seconds the ranking stops once at least one config
# works (0 = the first working config wins), so a long list of dead configs cannot
# delay the proxy; configs that were not tested yet stay in $CONFIG_DIR. Each config
# gets STARTUP_CHECKS health checks here, not the full failure threshold.
rank_configs() {
    local configs
    configs=$(get_configs)
    [ -n "$configs" ] || return 0

    local results=""
    local config status ms
    local started=$(date +%s)
    while IFS= read -r config; do
        [ -n "$config" ] || continue
        if [ -n "$results" ] && [ $(($(date +%s) - started)) -ge "$RANK_BUDGET" ]; then
            log "Ranking budget (${RANK_BUDGET}s) reached: using what is tested, the rest is tried later"
            break
        fi
        [ "$config" != "$SKIP_CONFIG" ] || continue
        log "Speed test: $(basename "$config")"

        start_tunnel "$config"
        status=$?
        if [ "$status" -eq 2 ]; then
            log "Fatal staging error; leaving $(basename "$config") in $CONFIG_DIR"
            return 2
        fi
        if [ "$status" -eq 3 ]; then
            continue
        fi
        if [ "$status" -eq 4 ]; then
            log "Skipping $(basename "$config") after endpoint DNS failure without adding a strike"
            continue
        fi
        if [ "$status" -ne 0 ]; then
            log "Candidate bring-up failed for $(basename "$config")"
            awg-quick down wg0 > /dev/null 2>&1
            record_pending_failure "$config"
            continue
        fi

        if ! health_check_with_retries "$config" "$STARTUP_CHECKS"; then
            log "No connectivity for $(basename "$config")"
            awg-quick down wg0 > /dev/null 2>&1
            record_pending_failure "$config"
            continue
        fi

        ms=$(measure_latency)
        log "Speed test: $(basename "$config") = ${ms:-?} ms"
        ms=${ms:-999999}
        results="${results}${ms}	${config}
"

        awg-quick down wg0 > /dev/null 2>&1
    done <<EOF
$configs
EOF

    if [ -n "$results" ]; then
        : # The main loop commits these penalties only after a candidate activates.
    else
        log "No config became healthy; preserving configs and strike counts"
    fi

    printf '%s' "$results" | sort -n
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
discard_pending_failures
DNS_WINDOW_OPEN=0
handle_signal() {
    close_dns_window
    rm -f "${WG_CONF}.stage.$$" "${WG_CONF}.resolved.$$"
    rm -f "$ACTIVE_MARKER"
    awg-quick down wg0 > /dev/null 2>&1
    exit 0
}
trap 'handle_signal' INT TERM

log "Failover manager started"
log "Config dir: $CONFIG_DIR | Bad dir: $BAD_DIR"
log "Interval: ${INTERVAL}s | Failure threshold: $FAIL_THRESHOLD | Speed test: $SPEED_TEST"

CURRENT_CONFIG=""
RANKED=""
FAST_TRIED=""
SKIP_CONFIG=""

while true; do
    # No active config — pick the fastest known one.
    if [ -z "$CURRENT_CONFIG" ]; then
        # Fast start: after a restart, try the config that worked last time before
        # ranking anything. Only if it fails does the full ranking run.
        if [ -z "$RANKED" ] && [ "$FAST_START" = "1" ] && [ -z "$FAST_TRIED" ]; then
            FAST_TRIED=1
            LAST=$(cat "$LAST_ACTIVE_FILE" 2>/dev/null)
            if [ -n "$LAST" ] && [ -f "$CONFIG_DIR/$LAST" ]; then
                log "Fast start: trying the last working config $LAST first"
                RANKED=$(printf '0\t%s\n' "$CONFIG_DIR/$LAST")
                SKIP_CONFIG="$CONFIG_DIR/$LAST"
            fi
        fi

        if [ -z "$RANKED" ]; then
            if [ "$SPEED_TEST" = "1" ]; then
                log "Ranking configs by latency..."
                RANKED=$(rank_configs)
                RANK_STATUS=$?
                SKIP_CONFIG=""
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
        if [ "$START_STATUS" -eq 3 ]; then
            log "Skipping unsupported config $(basename "$CURRENT_CONFIG")"
            CURRENT_CONFIG=""
            [ -n "$RANKED" ] || sleep "$CONFIG_POLL_INTERVAL"
            continue
        fi
        if [ "$START_STATUS" -eq 4 ]; then
            log "Skipping $(basename "$CURRENT_CONFIG") after endpoint DNS failure without adding a strike"
            CURRENT_CONFIG=""
            [ -n "$RANKED" ] || sleep "$CONFIG_POLL_INTERVAL"
            continue
        fi
        if [ "$START_STATUS" -ne 0 ]; then
            log "Candidate bring-up failed for $(basename "$CURRENT_CONFIG")"
            awg-quick down wg0 > /dev/null 2>&1
            record_pending_failure "$CURRENT_CONFIG"
            CURRENT_CONFIG=""
            [ -n "$RANKED" ] || sleep "$CONFIG_POLL_INTERVAL"
            continue
        fi

        if ! health_check_with_retries "$CURRENT_CONFIG" "$STARTUP_CHECKS"; then
            awg-quick down wg0 > /dev/null 2>&1
            record_pending_failure "$CURRENT_CONFIG"
            CURRENT_CONFIG=""
            [ -n "$RANKED" ] || sleep "$CONFIG_POLL_INTERVAL"
            continue
        fi

        commit_pending_failures "$CURRENT_CONFIG"
        SKIP_CONFIG=""
        STABLE_COUNT=0
        log "Config $(basename "$CURRENT_CONFIG") is ACTIVE"
        printf '%s\n' "$CURRENT_CONFIG" > "$ACTIVE_MARKER"
        basename "$CURRENT_CONFIG" > "$LAST_ACTIVE_FILE" 2>/dev/null || true
        echo "0" > "$FAILURE_FILE"
    fi

    # Monitoring loop
    sleep "$INTERVAL"

    "$CHECK_TUNNEL"
    if [ $? -eq 0 ]; then
        echo "0" > "$FAILURE_FILE"
        if [ ! -f "$ACTIVE_MARKER" ]; then
            printf '%s\n' "$CURRENT_CONFIG" > "$ACTIVE_MARKER"
        fi
        STABLE_COUNT=$((STABLE_COUNT + 1))
        if [ "$STABLE_COUNT" -ge "$FAIL_THRESHOLD" ]; then
            clear_strikes "$CURRENT_CONFIG"
            STABLE_COUNT=0
        fi
        continue
    fi
    STABLE_COUNT=0

    # Health check failed
    FAIL_COUNT=$(cat "$FAILURE_FILE")
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "$FAIL_COUNT" > "$FAILURE_FILE"
    log "Health check failed ($FAIL_COUNT / $FAIL_THRESHOLD)"

    if [ "$FAIL_COUNT" -lt "$FAIL_THRESHOLD" ]; then
        continue
    fi

    # Threshold reached — first restart the tunnel on the same config
    log "Failure threshold reached."
    attempt=1
    recovered=0
    while [ "$attempt" -le "$TUNNEL_RESTARTS" ]; do
        log "Restarting tunnel ($attempt / $TUNNEL_RESTARTS): $(basename "$CURRENT_CONFIG")"
        if restart_tunnel "$CURRENT_CONFIG"; then
            recovered=1
            break
        fi
        attempt=$((attempt + 1))
    done
    if [ "$recovered" = 1 ]; then
        log "Tunnel recovered after restart: $(basename "$CURRENT_CONFIG")"
        echo "0" > "$FAILURE_FILE"
        continue
    fi

    # The restart did not help. Never quarantine the only config: an outage
    # on the server side must not leave the container without any config.
    if [ -z "$RANKED" ] && [ "$(get_configs | wc -l)" -le 1 ]; then
        log "Only config $(basename "$CURRENT_CONFIG"): keeping it, retrying in ${CONFIG_POLL_INTERVAL}s"
        echo "0" > "$FAILURE_FILE"
        sleep "$CONFIG_POLL_INTERVAL"
        continue
    fi

    # Otherwise switch config
    log "Switching config..."
    rm -f "$ACTIVE_MARKER"
    awg-quick down wg0 > /dev/null 2>&1
    record_pending_failure "$CURRENT_CONFIG"
    SKIP_CONFIG="$CURRENT_CONFIG"
    CURRENT_CONFIG=""
    echo "0" > "$FAILURE_FILE"

    # Small pause before trying next config
    sleep 2
done
