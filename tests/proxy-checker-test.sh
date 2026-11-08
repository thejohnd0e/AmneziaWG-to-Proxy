#!/bin/sh

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$TEST_DIR")
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

fail() { echo "FAIL: $1" >&2; exit 1; }

bin="$TMP_ROOT/bin"
mkdir -p "$bin" "$TMP_ROOT/configs" "$TMP_ROOT/bad" "$TMP_ROOT/etc"
export WG_CONF="$TMP_ROOT/etc/wg0.conf"

# awg-quick fails for a staged config marked FAILUP; check-tunnel fails for DEAD.
cat > "$bin/awg-quick" <<'EOF'
#!/bin/sh
[ "$1" = up ] || exit 0
! grep -q FAILUP "$WG_CONF"
EOF
cat > "$bin/check-tunnel" <<'EOF'
#!/bin/sh
grep -q '^DNS' "$WG_CONF" && { echo "DNS line was not stripped" >> "$CHECK_ERRORS"; }
! grep -q DEAD "$WG_CONF"
EOF
cat > "$bin/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
cat > "$bin/curl" <<'EOF'
#!/bin/sh
printf '204 0.050'
EOF
chmod +x "$bin/awg-quick" "$bin/check-tunnel" "$bin/timeout" "$bin/curl"

full='AllowedIPs = 0.0.0.0/0, ::/0'
printf '[Interface]\nDNS = 1.1.1.1\n[Peer]\n%s\n' "$full" > "$TMP_ROOT/configs/good one.conf"
printf '[Interface]\n# FAILUP\n[Peer]\n%s\n' "$full" > "$TMP_ROOT/configs/broken.conf"
printf '[Interface]\n# DEAD\n[Peer]\n%s\n' "$full" > "$TMP_ROOT/configs/dead.conf"
printf '[Interface]\n[Peer]\nAllowedIPs = 10.0.0.0/8\n' > "$TMP_ROOT/configs/split.conf"
printf 'older quarantined copy\n' > "$TMP_ROOT/bad/dead.conf"
printf 'unrelated\n' > "$TMP_ROOT/bad/old.conf"

status=0
PATH="$bin:$PATH" CHECK_TUNNEL="$bin/check-tunnel" TUN_SETUP=true GEOIP=0 CHECKER_PAUSE=0 \
    CHECK_ERRORS="$TMP_ROOT/check-errors" AWG_LOG="$TMP_ROOT/awg.log" HEALTH_LOG="$TMP_ROOT/health.log" \
    sh "$PROJECT_DIR/scripts/proxy-checker.sh" "$TMP_ROOT/configs" --bad-dir "$TMP_ROOT/bad" \
    > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || status=$?

[ "$status" -eq 1 ] || { cat "$TMP_ROOT/out" "$TMP_ROOT/err" >&2; fail "expected exit 1 with failed configs, got $status"; }
[ ! -e "$TMP_ROOT/check-errors" ] || fail "$(cat "$TMP_ROOT/check-errors")"
[ -f "$TMP_ROOT/configs/good one.conf" ] || fail "a working config with a space in its name was lost"
[ -f "$TMP_ROOT/configs/split.conf" ] || fail "a split-tunnel config must be skipped, not moved"
[ ! -e "$TMP_ROOT/configs/broken.conf" ] || fail "awg-quick failure must move the config"
[ ! -e "$TMP_ROOT/configs/dead.conf" ] || fail "a config without connectivity must move"
[ -f "$TMP_ROOT/bad/broken.conf" ] || fail "broken.conf missing from bad dir"
[ "$(cat "$TMP_ROOT/bad/dead.conf")" = "older quarantined copy" ] \
    || fail "an older quarantined config with the same name was overwritten"
renamed=0
for f in "$TMP_ROOT"/bad/dead.*.conf; do
    case "$(basename "$f")" in
        dead.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].conf) renamed=1 ;;
    esac
done
[ "$renamed" -eq 1 ] || fail "colliding name did not get a timestamp suffix"
grep -q 'good one.conf' "$TMP_ROOT/out" || fail "working config missing from the summary"
grep -q 'Skipped: 1' "$TMP_ROOT/out" || fail "skipped split tunnel not counted"
moved=$(sed -n '/Moved to bad_config/,/Tip:/p' "$TMP_ROOT/out")
printf '%s\n' "$moved" | grep -q 'broken.conf' || fail "moved list misses broken.conf"
if printf '%s\n' "$moved" | grep -q 'old.conf'; then
    fail "moved list must only name configs moved in this run"
fi

# A failed copy must leave the source in place.
mkdir -p "$TMP_ROOT/c2"
printf '[Interface]\n# DEAD\n[Peer]\n%s\n' "$full" > "$TMP_ROOT/c2/dead.conf"
# A read-only bad dir makes the move fail (skipped where permissions are not enforced, e.g. root).
mkdir -p "$TMP_ROOT/ro"
chmod 555 "$TMP_ROOT/ro"
if [ ! -w "$TMP_ROOT/ro" ]; then
    PATH="$bin:$PATH" CHECK_TUNNEL="$bin/check-tunnel" TUN_SETUP=true GEOIP=0 CHECKER_PAUSE=0 \
        CHECK_ERRORS="$TMP_ROOT/check-errors" AWG_LOG="$TMP_ROOT/awg.log" HEALTH_LOG="$TMP_ROOT/health.log" \
        sh "$PROJECT_DIR/scripts/proxy-checker.sh" "$TMP_ROOT/c2" --bad-dir "$TMP_ROOT/ro" \
        > /dev/null 2>&1 || true
    [ -f "$TMP_ROOT/c2/dead.conf" ] || fail "config deleted although moving it failed"
fi
chmod 755 "$TMP_ROOT/ro"

# Wrapper: .env values reach the container, the environment wins, comments are dropped.
cat > "$TMP_ROOT/test.env" <<'EOF'
FAILOVER_TIMEOUT=5            # seconds
HEALTH_URLS="https://a.example/204,https://b.example/204"
DNS_PRIMARY=9.9.9.9
DNS_SECONDARY=
LAN_NETWORK=10.0.0.0/8
EOF
out=$(DNS_PRIMARY=8.8.8.8 CHECKER_ENV_FILE="$TMP_ROOT/test.env" CHECKER_DRY_RUN=1 \
    bash "$PROJECT_DIR/proxy-checker" "$TMP_ROOT/configs" --bad-dir "$TMP_ROOT/bad")
printf '%s\n' "$out" | grep -qx 'FAILOVER_TIMEOUT=5' || fail "inline comment not stripped from .env value"
printf '%s\n' "$out" | grep -qx 'HEALTH_URLS=https://a.example/204,https://b.example/204' || fail "quoted .env value not read"
printf '%s\n' "$out" | grep -qx 'DNS_PRIMARY=8.8.8.8' || fail "environment must override .env"
printf '%s\n' "$out" | grep -qx 'DNS_SECONDARY=' || fail "empty .env value must stay unset"
if bash "$PROJECT_DIR/proxy-checker" "$TMP_ROOT/configs" --bad-dir > /dev/null 2>&1; then
    fail "--bad-dir without a value must be rejected"
fi

echo "PASS: proxy-checker keeps names, skips split tunnels, never overwrites or loses configs, reads .env"
