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
chmod 777 "$TMP_ROOT"
N="ip netns exec $NS"
DNS_SERVER_PID=""
DNS_CLIENT_PID=""

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

cleanup() {
    [ -z "$DNS_CLIENT_PID" ] || kill "$DNS_CLIENT_PID" 2>/dev/null || true
    [ -z "$DNS_SERVER_PID" ] || kill "$DNS_SERVER_PID" 2>/dev/null || true
    [ -z "$DNS_CLIENT_PID" ] || wait "$DNS_CLIENT_PID" 2>/dev/null || true
    [ -z "$DNS_SERVER_PID" ] || wait "$DNS_SERVER_PID" 2>/dev/null || true
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

printf '%s\n' 'nameserver 192.168.0.53' > "$TMP_ROOT/resolv.conf"
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
ip netns exec "$CLIENT_NS" ip addr add 192.168.0.53/32 dev ks-client
ip netns exec "$CLIENT_NS" ip link set lo up
ip netns exec "$CLIENT_NS" ip link set ks-client up
$N ip route add 192.168.0.53/32 via 10.200.0.2 dev ks-proxy

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

printf '%s\n' \
    'import os, socket, sys' \
    'uid = int(sys.argv[1])' \
    'os.setuid(uid) if uid else None' \
    's = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)' \
    'target = sys.argv[2] if len(sys.argv) > 2 else "192.168.0.53"' \
    's.sendto(b"\x00" * 12, (target, 53))' > "$TMP_ROOT/dns-send.py"

cat > "$TMP_ROOT/dns-tcp-server.py" <<'EOF'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("192.168.0.53", 53))
s.listen(1)
c, _ = s.accept()
c.recv(16)
open(sys.argv[1], "w").close()
while c.recv(1024):
    pass
c.close()
s.close()
EOF

cat > "$TMP_ROOT/dns-tcp-client.py" <<'EOF'
import os, socket, sys, time
os.setuid(65532)
s = socket.create_connection(("192.168.0.53", 53), 2)
s.sendall(b"first")
open(sys.argv[1], "w").close()
while not os.path.exists(sys.argv[2]):
    time.sleep(0.01)
try:
    s.sendall(b"after-close")
except OSError:
    open(sys.argv[3], "w").close()
s.close()
EOF

dns_helper_packets() {
    $N iptables -nvxL "$CHAIN" | awk '/owner UID match 65532/ { total += $1 } END { print total + 0 }'
}

dns_reject_packets() {
    $N iptables -nvxL "$CHAIN" | awk '/REJECT/ && /dpt:53/ { total += $1 } END { print total + 0 }'
}

dns_tcp_reject_packets() {
    $N iptables -nvxL "$CHAIN" | awk '/REJECT/ && /tcp dpt:53/ { total += $1 } END { print total + 0 }'
}

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
    e0=$(tx eth0)
    w0=$(tx wg0)
    $N python3 "$TMP_ROOT/dns-send.py" 0 1.1.1.1 >/dev/null 2>&1 || fail "could not send synthetic DNS on the tunnel"
    [ "$(( $(tx wg0) - w0 ))" -ge 1 ] \
        || fail "proxy DNS did not leave through wg0 while the tunnel was up"
    [ "$(( $(tx eth0) - e0 ))" = 0 ] \
        || fail "proxy DNS escaped through eth0 while the tunnel was up"
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
    LAN_NETWORK=192.168.0.0/16 $N sh "$KILLSWITCH" dns-open || fail "dns-open failed"
    $N iptables -S "$CHAIN" | grep -q -- "-d 192.168.0.53/32 -p udp -m owner --uid-owner 65532 -m udp --dport 53 -j ACCEPT" \
        || fail "dns-open did not allow DNS to the resolver: $($N iptables -S "$CHAIN")"
    helper_before=$(dns_helper_packets)
    reject_before=$(dns_reject_packets)
    $N python3 "$TMP_ROOT/dns-send.py" 65532 || fail "could not send a resolver-UID DNS packet"
    $N python3 "$TMP_ROOT/dns-send.py" 0 >/dev/null 2>&1 || true
    helper_after=$(dns_helper_packets)
    reject_after=$(dns_reject_packets)
    [ "$helper_after" -gt "$helper_before" ] \
        || fail "resolver UID packet did not match the scoped DNS exception"
    [ "$reject_after" -gt "$reject_before" ] \
        || fail "non-resolver packet to a private DNS server did not hit rejection despite LAN allow"
    reject_before_loopback=$(dns_reject_packets)
    $N python3 "$TMP_ROOT/dns-send.py" 0 127.0.0.1 >/dev/null 2>&1 || true
    reject_after_loopback=$(dns_reject_packets)
    [ "$reject_after_loopback" -gt "$reject_before_loopback" ] \
        || fail "non-resolver DNS to a loopback stub bypassed DNS rejection"
    ip netns exec "$CLIENT_NS" python3 "$TMP_ROOT/dns-tcp-server.py" "$TMP_ROOT/tcp-server-ready" >"$TMP_ROOT/tcp-server.log" 2>&1 &
    DNS_SERVER_PID=$!
    $N python3 "$TMP_ROOT/dns-tcp-client.py" "$TMP_ROOT/tcp-client-ready" "$TMP_ROOT/tcp-go" "$TMP_ROOT/tcp-blocked" >"$TMP_ROOT/tcp-client.log" 2>&1 &
    DNS_CLIENT_PID=$!
    attempts=0
    while [ ! -f "$TMP_ROOT/tcp-client-ready" ] && [ "$attempts" -lt 50 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
    [ -f "$TMP_ROOT/tcp-client-ready" ] || fail "could not establish synthetic TCP DNS stream: $(cat "$TMP_ROOT/tcp-client.log" "$TMP_ROOT/tcp-server.log" 2>/dev/null)"
    tcp_reject_before=$(dns_tcp_reject_packets)
    apply
    : > "$TMP_ROOT/tcp-go"
    attempts=0
    while [ "$(dns_tcp_reject_packets)" -le "$tcp_reject_before" ] && [ "$attempts" -lt 50 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
    tcp_reject_after=$(dns_tcp_reject_packets)
    [ "$tcp_reject_after" -gt "$tcp_reject_before" ] \
        || fail "an established TCP DNS stream bypassed closure"
    kill "$DNS_CLIENT_PID" "$DNS_SERVER_PID" 2>/dev/null || true
    wait "$DNS_CLIENT_PID" "$DNS_SERVER_PID" 2>/dev/null || true
    DNS_CLIENT_PID=""
    DNS_SERVER_PID=""
    if $N iptables -S "$CHAIN" | grep -q -- "192.168.0.53"; then
        fail "DNS stayed open after apply"
    fi
    echo "PASS: private resolver DNS is UID-scoped; proxy UID and established TCP DNS are blocked after closure"
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
