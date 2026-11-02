#!/bin/sh
# killswitch-test.sh — Kill switch behaviour in a throwaway network namespace
# Needs root, iproute2, iptables and iputils ping (-m). Everything happens inside
# a private netns that is removed afterwards; the host firewall is not touched.
#
#   sudo sh tests/killswitch-test.sh
#
# KILLSWITCH_SCRIPT=<file> runs the same scenarios with another script in place
# of scripts/killswitch.sh, e.g. a no-op, to check that the leak is detected.

set -u

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$TEST_DIR")
KILLSWITCH="${KILLSWITCH_SCRIPT:-$PROJECT_DIR/scripts/killswitch.sh}"
CHAIN=AWG_KILLSWITCH
NS="ks-test-$$"
CLIENT_NS="${NS}-client"
TMP_ROOT=$(mktemp -d)
N="ip netns exec $NS"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

cleanup() {
    ip netns del "$NS" 2>/dev/null || true
    ip netns del "$CLIENT_NS" 2>/dev/null || true
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

if [ "$(id -u)" != 0 ]; then
    echo "SKIP: killswitch tests need root (network namespaces)"
    exit 0
fi
command -v python3 > /dev/null || fail "python3 is required for the marked UDP probe"

# awg stand-in: reports the tunnel fwmark only while wg0 exists
mkdir -p "$TMP_ROOT/bin"
printf '%s\n' \
    '#!/bin/sh' \
    '[ "$1 $2 $3" = "show wg0 fwmark" ] || exit 1' \
    'ip link show wg0 > /dev/null 2>&1 || exit 1' \
    'echo 51820' > "$TMP_ROOT/bin/awg"
chmod +x "$TMP_ROOT/bin/awg"
export PATH="$TMP_ROOT/bin:$PATH"

printf '%s\n' 'nameserver 192.0.2.53' > "$TMP_ROOT/resolv.conf"
export RESOLV_CONF="$TMP_ROOT/resolv.conf"

ip netns add "$NS" || fail "cannot create network namespace $NS"
ip netns add "$CLIENT_NS" || fail "cannot create client namespace $CLIENT_NS"
$N ip link set lo up
$N ip link add eth0 type dummy
$N ip addr add 172.30.0.2/24 dev eth0
$N ip link set eth0 up
$N ip neigh replace 172.30.0.1 lladdr 02:00:00:00:00:01 nud permanent dev eth0
$N ip route add default via 172.30.0.1 dev eth0
ip link add ks-proxy type veth peer name ks-client
ip link set ks-proxy netns "$NS"
ip link set ks-client netns "$CLIENT_NS"
$N ip addr add 10.200.0.1/24 dev ks-proxy
$N ip link set ks-proxy up
ip netns exec "$CLIENT_NS" ip addr add 10.200.0.2/24 dev ks-client
ip netns exec "$CLIENT_NS" ip link set lo up
ip netns exec "$CLIENT_NS" ip link set ks-client up

# Mirrors what awg-quick sets up: wg0, table 51820 and the two policy rules
tunnel_up() {
    $N ip link add wg0 type dummy
    $N ip addr add 10.66.0.2/32 dev wg0
    $N ip link set wg0 up
    $N ip route add default dev wg0 table 51820
    $N ip rule add not fwmark 51820 table 51820
    $N ip rule add table main suppress_prefixlength 0
}

tunnel_down() {
    $N ip rule del not fwmark 51820 table 51820 2>/dev/null || true
    $N ip rule del table main suppress_prefixlength 0 2>/dev/null || true
    $N ip link del wg0 2>/dev/null || true
}

tx() {
    $N cat "/sys/class/net/$1/statistics/tx_packets" 2>/dev/null || echo 0
}

reject_count() {
    $N iptables -L "$CHAIN" -v -n -x 2>/dev/null \
        | awk '/REJECT/ { sum += $1; found = 1 } END { print found ? sum : 0 }'
}

# measure COMMAND...: runs the command and sets PROBE_ETH0, PROBE_WG0 and
# PROBE_REJECT to the packets it caused on each path
measure() {
    e0=$(tx eth0)
    w0=$(tx wg0)
    r0=$(reject_count)
    "$@" > /dev/null 2>&1
    PROBE_ETH0=$(( $(tx eth0) - e0 ))
    PROBE_WG0=$(( $(tx wg0) - w0 ))
    PROBE_REJECT=$(( $(reject_count) - r0 ))
}

# probe TARGET [ping options...]: one ICMP packet
probe() {
    target="$1"
    shift
    measure $N ping -c 1 -W 1 "$@" "$target"
}

# Stands in for the tunnel's own UDP socket: one datagram with fwmark 51820
printf '%s\n' \
    'import socket, sys' \
    's = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)' \
    's.setsockopt(socket.SOL_SOCKET, 36, int(sys.argv[1]))  # SO_MARK' \
    'try:' \
    '    s.sendto(b"x", (sys.argv[2], int(sys.argv[3])))' \
    'except OSError:' \
    '    pass' > "$TMP_ROOT/udp-send.py"

# probe_tunnel_socket TARGET: one marked UDP datagram, as the tunnel would send it
probe_tunnel_socket() {
    measure $N python3 "$TMP_ROOT/udp-send.py" 51820 "$1" 51820
}

apply() {
    $N sh "$KILLSWITCH" apply || fail "kill switch apply failed"
}

test_no_tunnel_blocks_public_traffic() {
    apply
    probe 203.0.113.10
    [ "$PROBE_ETH0" = 0 ] || fail "public traffic left via eth0 with no tunnel (+$PROBE_ETH0 packets)"
    [ "$PROBE_REJECT" -ge 1 ] || fail "public traffic with no tunnel was not rejected by the kill switch"
    echo "PASS: no tunnel blocks public traffic"
}

test_no_tunnel_keeps_lan_access() {
    LAN_NETWORK=192.168.0.0/24 $N sh "$KILLSWITCH" apply
    probe 192.168.0.12
    [ "$PROBE_ETH0" -ge 1 ] || fail "LAN traffic was not sent via eth0 with no tunnel"
    [ "$PROBE_REJECT" = 0 ] || fail "LAN traffic was rejected by the kill switch"
    apply
    echo "PASS: LAN access works with no tunnel"
}

test_private_and_metadata_destinations_block_by_default() {
    for target in 10.0.0.1 172.16.0.1 192.168.0.12 169.254.169.254; do
        probe "$target"
        [ "$PROBE_ETH0" = 0 ] || fail "private destination $target left via eth0"
        [ "$PROBE_REJECT" -ge 1 ] || fail "private destination $target was not rejected"
    done
    echo "PASS: private and metadata destinations are denied by default"
}

test_proxy_client_receives_tcp_reply_without_lan_egress_allowance() {
    cat > "$TMP_ROOT/proxy-server.py" <<'EOF'
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("10.200.0.1", 1080))
s.listen(1)
c, _ = s.accept()
c.recv(16)
c.sendall(b"proxy-reply")
c.close()
s.close()
EOF
    $N python3 "$TMP_ROOT/proxy-server.py" > /dev/null 2>&1 &
    server_pid=$!
    sleep 0.1
    response=$(ip netns exec "$CLIENT_NS" python3 -c \
        'import socket; s=socket.create_connection(("10.200.0.1",1080),2); s.sendall(b"request"); print(s.recv(32).decode()); s.close()') \
        || fail "proxy client TCP connection failed"
    wait "$server_pid" || fail "proxy listener did not complete"
    [ "$response" = proxy-reply ] || fail "client did not receive the proxy TCP response"
    echo "PASS: inbound proxy client receives TCP response"
}

test_tunnel_carries_public_traffic() {
    tunnel_up
    apply
    probe 169.254.169.254
    [ "$PROBE_ETH0" = 0 ] && [ "$PROBE_WG0" = 0 ] \
        || fail "metadata traffic escaped via the tunnel or eth0"
    [ "$PROBE_REJECT" -ge 1 ] || fail "metadata traffic was not rejected while tunnel was up"
    probe 203.0.113.10
    [ "$PROBE_WG0" -ge 1 ] || fail "public traffic did not use wg0 while the tunnel was up"
    [ "$PROBE_ETH0" = 0 ] || fail "public traffic left via eth0 while the tunnel was up (+$PROBE_ETH0)"
    echo "PASS: tunnel carries public traffic"
}

test_tunnel_socket_mark_reaches_endpoint() {
    # Stands in for the endpoint route wg-quick adds; marked packets skip table 51820
    $N ip route add 203.0.113.10/32 via 172.30.0.1 dev eth0
    probe_tunnel_socket 203.0.113.10
    $N ip route del 203.0.113.10/32 via 172.30.0.1 dev eth0
    [ "$PROBE_ETH0" -ge 1 ] || fail "marked tunnel-socket packet was not allowed out via eth0"
    [ "$PROBE_REJECT" = 0 ] || fail "marked tunnel-socket packet was rejected"
    echo "PASS: tunnel socket (fwmark) may reach the endpoint"
}

test_tunnel_down_blocks_public_traffic() {
    tunnel_down
    probe 203.0.113.10
    [ "$PROBE_ETH0" = 0 ] || fail "public traffic fell back to eth0 after wg0 went down (+$PROBE_ETH0)"
    [ "$PROBE_REJECT" -ge 1 ] || fail "public traffic after wg0 went down was not rejected"
    echo "PASS: tunnel down blocks public traffic"
}

test_tunnel_down_keeps_lan_access() {
    LAN_NETWORK=192.168.0.0/24 $N sh "$KILLSWITCH" apply
    probe 192.168.0.12
    [ "$PROBE_ETH0" -ge 1 ] || fail "LAN traffic was blocked after wg0 went down"
    apply
    echo "PASS: tunnel down keeps LAN access"
}

test_tunnel_socket_pinhole_closes_without_tunnel() {
    apply
    $N ip route add 203.0.113.10/32 via 172.30.0.1 dev eth0
    probe_tunnel_socket 203.0.113.10
    $N ip route del 203.0.113.10/32 via 172.30.0.1 dev eth0
    [ "$PROBE_ETH0" = 0 ] || fail "tunnel-socket mark still passed after the tunnel was removed (+$PROBE_ETH0)"
    echo "PASS: tunnel socket pinhole closes when the tunnel is gone"
}

test_apply_is_idempotent() {
    apply
    apply
    jumps=$($N iptables -S OUTPUT | grep -c "\-j $CHAIN\$")
    [ "$jumps" = 1 ] || fail "expected one OUTPUT jump to $CHAIN, found $jumps"
    echo "PASS: repeated apply keeps a single OUTPUT jump"
}

test_dns_window_opens_and_closes() {
    $N sh "$KILLSWITCH" dns-open || fail "dns-open failed"
    $N iptables -S "$CHAIN" | grep -q -- "-d 192.0.2.53/32 -p udp -m udp --dport 53 -j ACCEPT" \
        || fail "dns-open did not allow DNS to the resolver"
    apply
    if $N iptables -S "$CHAIN" | grep -q -- "192.0.2.53"; then
        fail "DNS stayed open after apply"
    fi
    echo "PASS: DNS is open only during dns-open"
}

test_no_tunnel_blocks_public_traffic
test_private_and_metadata_destinations_block_by_default
test_no_tunnel_keeps_lan_access
test_proxy_client_receives_tcp_reply_without_lan_egress_allowance
test_tunnel_carries_public_traffic
test_tunnel_socket_mark_reaches_endpoint
test_tunnel_down_blocks_public_traffic
test_tunnel_down_keeps_lan_access
test_tunnel_socket_pinhole_closes_without_tunnel
test_apply_is_idempotent
test_dns_window_opens_and_closes
echo "All kill switch tests passed"
