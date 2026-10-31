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
cat > /dev/null
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

sh "$PROJECT_DIR/scripts/killswitch.sh" apply
grep -q -- '-A AWG_KILLSWITCH -p udp -m mark --mark 0xca6c -j ACCEPT' "$RULES_CAPTURE" \
    || { echo "FAIL: hexadecimal tunnel fwmark was not allowed" >&2; exit 1; }

echo "PASS: hexadecimal tunnel fwmark is allowed"
