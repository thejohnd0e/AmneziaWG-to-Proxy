#!/bin/sh
# entrypoint.sh — Container entrypoint
# Replaces the upstream start.sh to integrate failover manager.

term_handler() {
    echo "--- [entrypoint] Stopping Amnezia tunnel ---"
    awg-quick down wg0 > /dev/null 2>&1
    kill $(pidof sleep) 2>/dev/null
    exit 0
}

trap 'term_handler' SIGTERM

# Start failover manager in background
/failover-manager.sh &
FAILOVER_PID=$!

# Wait for first active config (poll /tmp/active_config)
echo "--- [entrypoint] Waiting for first active config ---"
WAIT_COUNT=0
while [ ! -f /tmp/active_config ]; do
    if ! kill -0 "$FAILOVER_PID" 2>/dev/null; then
        wait "$FAILOVER_PID"
        FAILOVER_STATUS=$?
        echo "--- [entrypoint] Failover manager exited with status $FAILOVER_STATUS ---"
        exit "$FAILOVER_STATUS"
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [ "$WAIT_COUNT" -ge 120 ]; then
        echo "--- [entrypoint] Timeout waiting for active config (10 min) ---"
        kill "$FAILOVER_PID" 2>/dev/null
        exit 1
    fi
done

echo "--- [entrypoint] Active config established, starting proxies ---"

# Grab gateway before adding routes
IP4GATEWAY=$(ip route | awk '/default/ { print $3 }')
IP6GATEWAY=$(ip -6 route | awk '/default/ { print $3 }')

# Local network bypass rules (from upstream)
iptables -I OUTPUT -d 192.168.0.0/16 -j ACCEPT
iptables -I OUTPUT -d 172.16.0.0/12 -j ACCEPT
iptables -I OUTPUT -d 10.0.0.0/8 -j ACCEPT
ip6tables -I OUTPUT -d fc00::/7 -j ACCEPT
ip6tables -I OUTPUT -d fe80::/10 -j ACCEPT
ip6tables -I OUTPUT -d ff00::/8 -j ACCEPT

# Start SOCKS5 proxy
./microsocks -q -i :: -p 1080 &

# Start HTTP proxy (Privoxy)
sed -i "s|listen-address \[::\]:.*|listen-address [::]:${HTTPPORT}|" /etc/privoxy/config
privoxy /etc/privoxy/config

echo "--- [entrypoint] Proxies started (SOCKS5:1080, HTTP:${HTTPPORT}) ---"

# Supervise failover manager
while true; do
    wait "$FAILOVER_PID"
    exit $?
done
