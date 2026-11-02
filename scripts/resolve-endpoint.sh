#!/bin/sh
# Resolve one hostname through configured numeric resolvers, without Docker DNS.

RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"

is_ipv4() {
    awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++)
                if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i > 255 || ($i != "0" && substr($i, 1, 1) == "0")) exit 1
        }
    ' <<EOF
$1
EOF
}

is_ipv6() {
    awk '
        function groups(s, a, n, i) {
            if (s == "") return 0
            n = split(s, a, ":")
            for (i = 1; i <= n; i++)
                if (a[i] !~ /^[[:xdigit:]]+$/ || length(a[i]) > 4) return -100
            return n
        }
        {
            s = $0
            if (s !~ /^[0-9A-Fa-f:]+$/ || s ~ /:::/) exit 1
            p = index(s, "::")
            if (p) {
                left = substr(s, 1, p - 1)
                right = substr(s, p + 2)
                if (index(right, "::")) exit 1
                n = groups(left) + groups(right)
                if (n < 0 || n >= 8) exit 1
            } else if (groups(s) != 8) exit 1
            compact = s
            gsub(/:/, "", compact)
            if (compact == "" || compact ~ /^0+$/) exit 1
        }
    ' <<EOF
$1
EOF
}

is_resolver_address() {
    case "$1" in
        *:*) is_ipv6 "$1" ;;
        *) is_ipv4 "$1" ;;
    esac
}

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: resolve-endpoint.sh <hostname>" >&2
    exit 1
fi

HOST=${1%.}
case "$HOST" in
    ''|.*|*..*|*[!A-Za-z0-9.-]*|*-)
        echo "ERROR: invalid endpoint hostname" >&2
        exit 1
        ;;
esac
[ "${#HOST}" -le 253 ] || {
    echo "ERROR: endpoint hostname is too long" >&2
    exit 1
}
if ! printf '%s\n' "$HOST" | awk -F. '{
    for (i = 1; i <= NF; i++)
        if (length($i) == 0 || length($i) > 63 || $i ~ /^-/ || $i ~ /-$/) exit 1
}'; then
    echo "ERROR: invalid endpoint hostname" >&2
    exit 1
fi

command -v dig > /dev/null 2>&1 || {
    echo "ERROR: dig is required for endpoint resolution" >&2
    exit 2
}
[ -r "$RESOLV_CONF" ] || {
    echo "ERROR: resolver configuration is not readable" >&2
    exit 2
}

SERVERS=$(awk '$1 == "nameserver" { print $2 }' "$RESOLV_CONF")
[ -n "$SERVERS" ] || {
    echo "ERROR: no configured numeric DNS resolver" >&2
    exit 2
}
for server in $SERVERS; do
    if ! is_resolver_address "$server"; then
        echo "ERROR: malformed DNS resolver configuration" >&2
        exit 2
    fi
    case "$server" in
        127.*|0.0.0.0|::|::1)
            echo "ERROR: loopback/unspecified and Docker embedded DNS are unsupported" >&2
            exit 2
            ;;
    esac
done

for type in A AAAA; do
    for server in $SERVERS; do
        ANSWERS=$(dig +time=2 +tries=1 +noall +answer "@$server" "$HOST" "$type" 2>/dev/null || true)
        ADDRESS=$(printf '%s\n' "$ANSWERS" | awk -v type="$type" '$4 == type { print $5; exit }')
        if [ "$type" = A ] && is_ipv4 "$ADDRESS"; then
            printf '%s\n' "$ADDRESS"
            exit 0
        fi
        if [ "$type" = AAAA ] && is_ipv6 "$ADDRESS"; then
            printf '%s\n' "$ADDRESS"
            exit 0
        fi
    done
done

exit 1
