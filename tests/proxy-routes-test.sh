#!/bin/sh

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$TEST_DIR")
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ROUTE_CALLS"
case "$*" in
    *"$FAIL_NETWORK"*) [ -z "$FAIL_NETWORK" ] && exit 0; exit 1 ;;
esac
exit 0
EOF
chmod +x "$TMP_ROOT/bin/ip"
export PATH="$TMP_ROOT/bin:$PATH"
export ROUTE_CALLS="$TMP_ROOT/routes"
export FAIL_NETWORK=''

LAN_NETWORK='192.168.1.0/24,10.20.0.0/16' \
LAN_NETWORK6='fd12:3456::/64' \
PROXY_CLIENT_NETWORKS='100.64.1.0/24' \
PROXY_CLIENT_NETWORKS6='2001:db8:2::/64' \
IP4GATEWAY=172.30.0.1 IP6GATEWAY=fe80::1 \
    sh "$PROJECT_DIR/scripts/proxy-routes.sh"

for route in \
    'route replace 192.168.1.0/24 via 172.30.0.1 dev eth0 onlink' \
    'route replace 10.20.0.0/16 via 172.30.0.1 dev eth0 onlink' \
    'route replace 100.64.1.0/24 via 172.30.0.1 dev eth0 onlink' \
    '-6 route replace fd12:3456::/64 via fe80::1 dev eth0 onlink' \
    '-6 route replace 2001:db8:2::/64 via fe80::1 dev eth0 onlink'; do
    grep -Fxq -- "$route" "$ROUTE_CALLS" \
        || { echo "FAIL: missing exact route [$route]" >&2; exit 1; }
done
if grep -Eq '192\.168\.0\.0/16|10\.0\.0\.0/8|172\.16\.0\.0/12' "$ROUTE_CALLS"; then
    echo "FAIL: route set was widened beyond the configured CIDRs" >&2
    exit 1
fi

: > "$ROUTE_CALLS"
if LAN_NETWORK='' LAN_NETWORK6=' ,  ' PROXY_CLIENT_NETWORKS='' PROXY_CLIENT_NETWORKS6='' \
    IP4GATEWAY=172.30.0.1 IP6GATEWAY='' sh "$PROJECT_DIR/scripts/proxy-routes.sh"; then
    :
else
    echo "FAIL: empty route lists were rejected without gateways" >&2
    exit 1
fi
[ ! -s "$ROUTE_CALLS" ] || { echo "FAIL: empty route lists called ip" >&2; exit 1; }

: > "$ROUTE_CALLS"
if LAN_NETWORK='192.168.1.0/24' IP4GATEWAY='' sh "$PROJECT_DIR/scripts/proxy-routes.sh"; then
    echo "FAIL: missing gateway accepted for required LAN route" >&2
    exit 1
fi
[ ! -s "$ROUTE_CALLS" ] || { echo "FAIL: route was added without a gateway" >&2; exit 1; }

: > "$ROUTE_CALLS"
if LAN_NETWORK='192.168.1.0/33' IP4GATEWAY=172.30.0.1 sh "$PROJECT_DIR/scripts/proxy-routes.sh"; then
    echo "FAIL: invalid IPv4 prefix was accepted" >&2
    exit 1
fi
[ ! -s "$ROUTE_CALLS" ] || { echo "FAIL: invalid CIDR reached the route command" >&2; exit 1; }

: > "$ROUTE_CALLS"
if LAN_NETWORK='192.168.1.0/24,10.20.0.0/16' IP4GATEWAY=172.30.0.1 FAIL_NETWORK=10.20.0.0/16 \
    sh "$PROJECT_DIR/scripts/proxy-routes.sh"; then
    echo "FAIL: failed route transaction unexpectedly succeeded" >&2
    exit 1
fi
grep -Fxq 'route del 192.168.1.0/24 via 172.30.0.1 dev eth0' "$ROUTE_CALLS" \
    || { echo "FAIL: route setup failure did not roll back the earlier route" >&2; exit 1; }

echo "PASS: exact routes are installed, gateways validated and partial setup rolled back"
