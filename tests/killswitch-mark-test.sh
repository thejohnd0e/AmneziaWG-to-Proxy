#!/bin/sh

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$TEST_DIR")
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/awg" <<'EOF'
#!/bin/sh
[ "$*" = "show wg0 fwmark" ] || exit 1
echo 0xca6c
EOF
cat > "$TMP_ROOT/bin/iptables-restore" <<'EOF'
#!/bin/sh
cat > "$RULES_CAPTURE"
EOF
cat > "$TMP_ROOT/bin/iptables" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP_ROOT/bin/ip6tables-restore" <<'EOF'
#!/bin/sh
cat > "$RULES6_CAPTURE"
EOF
cat > "$TMP_ROOT/bin/ip6tables" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP_ROOT/bin/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP_ROOT/bin"/*

export PATH="$TMP_ROOT/bin:$PATH"
export RULES_CAPTURE="$TMP_ROOT/rules"
export RULES6_CAPTURE="$TMP_ROOT/rules6"
export RESOLV_CONF="$TMP_ROOT/resolv.conf"
printf '%s\n' 'nameserver 192.168.0.1' 'nameserver 1.1.1.1' 'nameserver 2001:db8::53' > "$RESOLV_CONF"

sh "$PROJECT_DIR/scripts/killswitch.sh" apply
grep -q -- '-A AWG_KILLSWITCH -p udp -m mark --mark 0xca6c -j ACCEPT' "$RULES_CAPTURE" \
    || { echo "FAIL: hexadecimal tunnel fwmark was not allowed" >&2; exit 1; }

for network in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
    grep -Fq -- "-A AWG_KILLSWITCH -d $network -j REJECT --reject-with icmp-admin-prohibited" "$RULES_CAPTURE" \
        || { echo "FAIL: private destination $network is not blocked by default" >&2; exit 1; }
done
if grep -Eq -- '-A AWG_KILLSWITCH -d (10\.0\.0\.0/8|172\.16\.0\.0/12|192\.168\.0\.0/16|169\.254\.0\.0/16) -j ACCEPT' "$RULES_CAPTURE"; then
    echo "FAIL: a broad private-range exception is still enabled by default" >&2
    exit 1
fi

LAN_NETWORK=192.168.1.0/24 sh "$PROJECT_DIR/scripts/killswitch.sh" apply
grep -Fq -- '-A AWG_KILLSWITCH -d 192.168.1.0/24 -j ACCEPT' "$RULES_CAPTURE" \
    || { echo "FAIL: explicit destination allowlist was not applied" >&2; exit 1; }
if grep -Fq -- '-A AWG_KILLSWITCH -d 192.168.0.0/16 -j ACCEPT' "$RULES_CAPTURE"; then
    echo "FAIL: explicit allowlist was widened to the built-in private range" >&2
    exit 1
fi
grep -Fq -- '-A AWG_KILLSWITCH -p tcp -m conntrack --ctstate ESTABLISHED --ctdir REPLY --sport 1080 -j ACCEPT' "$RULES6_CAPTURE" \
    || { echo "FAIL: IPv6 proxy-client TCP replies are not allowed" >&2; exit 1; }

LAN_NETWORK=192.168.1.0/24 sh "$PROJECT_DIR/scripts/killswitch.sh" dns-open
grep -Fq -- '-A AWG_KILLSWITCH -p udp -m owner --uid-owner 65532 -d 192.168.0.1 --dport 53 -j ACCEPT' "$RULES_CAPTURE" \
    || { echo "FAIL: resolver UID lacks exact IPv4 UDP DNS permission" >&2; exit 1; }
grep -Fq -- '-A AWG_KILLSWITCH -p tcp -m owner --uid-owner 65532 -d 1.1.1.1 --dport 53 -j ACCEPT' "$RULES_CAPTURE" \
    || { echo "FAIL: resolver UID lacks exact IPv4 TCP DNS permission" >&2; exit 1; }
grep -Fq -- '-A AWG_KILLSWITCH -p udp -m owner --uid-owner 65532 -d 2001:db8::53 --dport 53 -j ACCEPT' "$RULES6_CAPTURE" \
    || { echo "FAIL: resolver UID lacks exact IPv6 DNS permission" >&2; exit 1; }
if grep -Eq -- '^-A AWG_KILLSWITCH -p (udp|tcp) -d (192\.168\.0\.1|1\.1\.1\.1) --dport 53 -j ACCEPT$' "$RULES_CAPTURE"; then
    echo "FAIL: DNS exception is not UID-scoped" >&2
    exit 1
fi
dns_tunnel_line=$(grep -nF -- '-A AWG_KILLSWITCH -o wg0 -p udp --dport 53 -j ACCEPT' "$RULES_CAPTURE" | cut -d: -f1)
dns_reject_line=$(grep -nF -- '-A AWG_KILLSWITCH -p udp --dport 53 -j REJECT --reject-with icmp-admin-prohibited' "$RULES_CAPTURE" | cut -d: -f1)
loopback_allow_line=$(grep -nF -- '-A AWG_KILLSWITCH -o lo -j ACCEPT' "$RULES_CAPTURE" | cut -d: -f1)
lan_allow_line=$(grep -nF -- '-A AWG_KILLSWITCH -d 192.168.1.0/24 -j ACCEPT' "$RULES_CAPTURE" | cut -d: -f1)
[ -n "$dns_tunnel_line" ] && [ -n "$dns_reject_line" ] \
    && [ "$dns_tunnel_line" -lt "$dns_reject_line" ] \
    && [ "$dns_reject_line" -lt "$loopback_allow_line" ] \
    && [ "$dns_reject_line" -lt "$lan_allow_line" ] \
    || { echo "FAIL: non-resolver DNS must be tunneled or rejected before loopback/LAN exceptions" >&2; exit 1; }
loopback_line=$(grep -nF -- '-A AWG_KILLSWITCH -o lo -j ACCEPT' "$RULES_CAPTURE" | cut -d: -f1)
reject_line=$(grep -nF -- '-A AWG_KILLSWITCH -p udp -d 127.0.0.11 --dport 53 -j REJECT' "$RULES_CAPTURE" | cut -d: -f1)
[ -n "$reject_line" ] && [ "$reject_line" -lt "$loopback_line" ] \
    || { echo "FAIL: Docker embedded DNS must be denied before loopback allow" >&2; exit 1; }

sh "$PROJECT_DIR/scripts/killswitch.sh" apply
if grep -Fq -- '-m owner --uid-owner 65532' "$RULES_CAPTURE"; then
    echo "FAIL: DNS exception survived closure" >&2
    exit 1
fi

echo "PASS: private/LAN policy and UID-scoped, closable direct DNS rules"
