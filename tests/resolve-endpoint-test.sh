#!/bin/sh

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$TEST_DIR")
RESOLVER="$PROJECT_DIR/scripts/resolve-endpoint.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/dig" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DIG_CALLS"
query_type=
host=
for arg do
    case "$arg" in
        A|AAAA) query_type="$arg" ;;
        @*) ;;
        +*) ;;
        *) host="$arg" ;;
    esac
done
case "$host:$query_type" in
    ipv4.example:A) printf '%s\n' 'ipv4.example. 10 IN A 203.0.113.9' ;;
    ipv4.example:AAAA) exit 0 ;;
    ipv6.example:A) exit 0 ;;
    ipv6.example:AAAA) printf '%s\n' 'ipv6.example. 10 IN AAAA 2001:db8::42' ;;
    malformed.example:A) printf '%s\n' 'malformed.example. 10 IN A not-an-address' ;;
    *.example:*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/dig"
export PATH="$TMP_ROOT/bin:$PATH"
export RESOLV_CONF="$TMP_ROOT/resolv.conf"
export DIG_CALLS="$TMP_ROOT/dig-calls"
printf '%s\n' 'nameserver 192.0.2.53' 'nameserver 2001:db8::53' > "$RESOLV_CONF"

actual=$(sh "$RESOLVER" ipv4.example)
[ "$actual" = '203.0.113.9' ] \
    || { echo "FAIL: expected validated IPv4 answer, got [$actual]" >&2; exit 1; }

actual=$(sh "$RESOLVER" ipv6.example)
[ "$actual" = '2001:db8::42' ] \
    || { echo "FAIL: expected validated IPv6 answer, got [$actual]" >&2; exit 1; }

if sh "$RESOLVER" malformed.example > /dev/null 2>&1; then
    echo "FAIL: malformed resolver output was accepted" >&2
    exit 1
fi

printf '%s\n' 'nameserver 127.0.0.11' > "$RESOLV_CONF"
if sh "$RESOLVER" ipv4.example > /dev/null 2>&1; then
    echo "FAIL: embedded Docker DNS fallback was accepted" >&2
    exit 1
fi

grep -Fq '@192.0.2.53 ipv4.example A' "$DIG_CALLS" \
    || { echo "FAIL: IPv4 query did not use the exact configured resolver" >&2; exit 1; }
grep -Fq '@192.0.2.53 ipv6.example AAAA' "$DIG_CALLS" \
    || { echo "FAIL: IPv6 answer query did not use the exact configured resolver" >&2; exit 1; }

echo "PASS: endpoint resolver uses explicit numeric DNS servers and validates A/AAAA answers"
