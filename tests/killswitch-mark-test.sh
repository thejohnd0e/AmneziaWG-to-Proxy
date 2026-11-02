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

echo "PASS: private destinations are denied by default and explicit LAN CIDRs stay exact"
