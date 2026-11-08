#!/bin/sh
# entrypoint.sh — Container entrypoint
# Replaces the upstream start.sh to integrate failover manager.

# The proxy ports are fixed: Compose publishes 1080/8080 and the kill switch
# only lets replies leave from these ports.
SOCKS_PORT=1080
HTTP_PORT=8080
SUPERVISE_INTERVAL="${SUPERVISE_INTERVAL:-5}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"
WAIT_LIMIT="${WAIT_LIMIT:-120}"
ACTIVE_MARKER="${ACTIVE_MARKER:-/tmp/active_config}"
KILLSWITCH="${KILLSWITCH:-/killswitch.sh}"
PROXY_ROUTES="${PROXY_ROUTES:-/proxy-routes.sh}"
FAILOVER_MANAGER="${FAILOVER_MANAGER:-/failover-manager.sh}"
PRIVOXY_CONFIG="${PRIVOXY_CONFIG:-/etc/privoxy/config}"
MICROSOCKS="${MICROSOCKS:-./microsocks}"

FAILOVER_PID=""
SOCKS_PID=""
HTTP_PID=""

log() {
    echo "--- [entrypoint] $1 ---"
}

stop_children() {
    for pid in $SOCKS_PID $HTTP_PID; do
        kill "$pid" 2>/dev/null
    done
    if [ -n "$FAILOVER_PID" ] && kill -0 "$FAILOVER_PID" 2>/dev/null; then
        # The manager takes the tunnel down on TERM, but a shell runs its trap only
        # after a foreground sleep ends: wait briefly, Docker's stop timeout is short.
        kill -TERM "$FAILOVER_PID" 2>/dev/null
        n=0
        while [ "$n" -lt 3 ] && kill -0 "$FAILOVER_PID" 2>/dev/null; do
            sleep 1
            n=$((n + 1))
        done
    fi
}

term_handler() {
    log "Stopping Amnezia tunnel"
    stop_children
    awg-quick down wg0 > /dev/null 2>&1
    exit 0
}

trap 'term_handler' TERM INT

# Sleep in the background so a signal is handled at once, not after the sleep.
pause() {
    sleep "$1" &
    wait $!
}

start_socks() {
    "$MICROSOCKS" -q -i :: -p "$SOCKS_PORT" &
    SOCKS_PID=$!
}

start_http() {
    privoxy --no-daemon "$PRIVOXY_CONFIG" &
    HTTP_PID=$!
}

if [ -n "${HTTPPORT:-}" ] && [ "$HTTPPORT" != "$HTTP_PORT" ]; then
    log "WARNING: HTTPPORT=$HTTPPORT is ignored; the HTTP proxy always listens on $HTTP_PORT inside the container"
fi

# A marker left over from before `docker restart` must not pass for a live tunnel
rm -f "$ACTIVE_MARKER"

# Arm the kill switch before anything can send traffic: only the tunnel, LAN and
# the tunnel's own socket may leave the container, with or without wg0.
if ! "$KILLSWITCH" apply; then
    log "Kill switch could not be armed, refusing to start"
    exit 1
fi

# Preserve the Docker gateway before awg-quick installs tunnel policy routes.
IP4GATEWAY=$(ip route | awk '/default/ { print $3; exit }')
IP6GATEWAY=$(ip -6 route | awk '/default/ { print $3; exit }')

if ! IP4GATEWAY="$IP4GATEWAY" IP6GATEWAY="$IP6GATEWAY" "$PROXY_ROUTES"; then
    log "Explicit LAN/client routes could not be installed; refusing to start"
    exit 1
fi

# Start failover manager in background
"$FAILOVER_MANAGER" &
FAILOVER_PID=$!

manager_exit() {
    wait "$FAILOVER_PID"
    status=$?
    FAILOVER_PID=""
    log "Failover manager exited with status $status"
    stop_children
    exit "$status"
}

# Wait for the first active config
log "Waiting for first active config"
WAIT_COUNT=0
while [ ! -f "$ACTIVE_MARKER" ]; do
    kill -0 "$FAILOVER_PID" 2>/dev/null || manager_exit
    pause "$WAIT_INTERVAL"
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [ "$WAIT_COUNT" -ge "$WAIT_LIMIT" ]; then
        log "Timeout waiting for active config"
        stop_children
        exit 1
    fi
done

log "Active config established, starting proxies"

sed -i "s|listen-address \[::\]:.*|listen-address [::]:${HTTP_PORT}|" "$PRIVOXY_CONFIG"
start_socks
start_http

log "Proxies started (SOCKS5:$SOCKS_PORT, HTTP:$HTTP_PORT)"

# Supervise: the manager's exit ends the container, a crashed proxy is restarted.
while true; do
    pause "$SUPERVISE_INTERVAL"
    kill -0 "$FAILOVER_PID" 2>/dev/null || manager_exit
    if ! kill -0 "$SOCKS_PID" 2>/dev/null; then
        wait "$SOCKS_PID" 2>/dev/null
        log "SOCKS5 proxy exited; restarting it"
        start_socks
    fi
    if ! kill -0 "$HTTP_PID" 2>/dev/null; then
        wait "$HTTP_PID" 2>/dev/null
        log "HTTP proxy exited; restarting it"
        start_http
    fi
done
