#!/bin/sh

set -eu

IMAGE="${IMAGE:-amnezia-bridge-failover:local}"
CONTAINER="proxy-dns-policy-test-$$"

cleanup() {
    docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker run -d --name "$CONTAINER" --network bridge --dns 1.1.1.1 \
    --cap-add NET_ADMIN --entrypoint /bin/sh "$IMAGE" -c 'sleep 300' > /dev/null

# Packet capture is a test-only tool installed into this disposable container.
docker exec "$CONTAINER" apk add --no-cache tcpdump > /dev/null
docker exec "$CONTAINER" /killswitch.sh apply
docker exec "$CONTAINER" /bin/sh -c \
    '/microsocks -q -i :: -p 1080 >/tmp/microsocks-test.log 2>&1 & privoxy --no-daemon /etc/privoxy/config >/tmp/privoxy-test.log 2>&1 & sleep 1'
docker exec -d "$CONTAINER" tcpdump -Z root -n -i eth0 -w /tmp/dns-eth0.pcap 'port 53'
sleep 1

reject_packets() {
    docker exec "$CONTAINER" iptables -nvxL AWG_KILLSWITCH \
        | awk '/REJECT/ && /dpt:53/ { total += $1 } END { print total + 0 }'
}

tunnel_dns_packets() {
    docker exec "$CONTAINER" iptables -nvxL AWG_KILLSWITCH \
        | awk '/ACCEPT/ && /wg0/ && /dpt:53/ { total += $1 } END { print total + 0 }'
}

reject_before=$(reject_packets)
host="dns-policy-$$.invalid"

if docker exec "$CONTAINER" curl --noproxy '' --max-time 4 \
    --socks5-hostname 127.0.0.1:1080 "http://$host/" > /dev/null 2>&1; then
    echo "FAIL: SOCKS5 remote-DNS request unexpectedly succeeded without a tunnel" >&2
    exit 1
fi

if docker exec "$CONTAINER" curl --noproxy '' --max-time 4 \
    -x http://127.0.0.1:8080 "http://$host/" > /dev/null 2>&1; then
    echo "FAIL: HTTP-proxy hostname request unexpectedly succeeded without a tunnel" >&2
    exit 1
fi

reject_after=$(reject_packets)
[ "$((reject_after - reject_before))" -ge 2 ] \
    || { echo "FAIL: SOCKS5/HTTP proxy DNS requests did not both hit the kill-switch DNS reject" >&2; exit 1; }

# Model the route rules a working wg-quick tunnel installs. The interface is a
# disposable dummy: DNS must be selected for wg0 by routing/firewall policy, not
# actually reach an external resolver.
docker exec "$CONTAINER" /bin/sh -ec '
    ip link add wg0 type dummy
    ip link set wg0 up
    ip route add default dev wg0 table 51820
    ip rule add not fwmark 51820 table 51820
    ip rule add table main suppress_prefixlength 0
    /killswitch.sh apply
'
tunnel_before=$(tunnel_dns_packets)
host="dns-policy-tunnel-$$.invalid"
docker exec "$CONTAINER" curl --noproxy '' --max-time 4 \
    --socks5-hostname 127.0.0.1:1080 "http://$host/" > /dev/null 2>&1 || true
docker exec "$CONTAINER" curl --noproxy '' --max-time 4 \
    -x http://127.0.0.1:8080 "http://$host/" > /dev/null 2>&1 || true
tunnel_after=$(tunnel_dns_packets)
[ "$tunnel_after" -gt "$tunnel_before" ] \
    || { echo "FAIL: live proxy DNS did not use wg0 while the tunnel route was present" >&2; exit 1; }

docker exec "$CONTAINER" /bin/sh -c 'kill "$(pidof tcpdump)" 2>/dev/null || true'
sleep 0.2
captured_dns=$(docker exec "$CONTAINER" tcpdump -nn -r /tmp/dns-eth0.pcap 2>/dev/null || true)
if [ -n "$captured_dns" ]; then
    echo "FAIL: direct eth0 packet capture observed DNS traffic: $captured_dns" >&2
    exit 1
fi

echo "PASS: live SOCKS5/HTTP hostname requests are rejected without a tunnel, use wg0 with a tunnel route, and emit no DNS on captured eth0"
