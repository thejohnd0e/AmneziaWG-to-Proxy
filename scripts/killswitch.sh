#!/bin/sh
# shellcheck disable=SC3043 # Alpine's supported BusyBox ash and the test dash provide function-local variables.
# killswitch.sh — Outbound kill switch for the container
# Owns the AWG_KILLSWITCH chain, hooked into OUTPUT. Only loopback, the tunnel
# interface, LAN ranges and the tunnel's own UDP socket (matched by its fwmark)
# may leave the container. Everything else is rejected, so when wg0 is missing
# or down, traffic cannot fall back to the default route on eth0.
#
#   killswitch.sh apply     rebuild the chain for the current tunnel state
#   killswitch.sh dns-open  same, and also allow DNS to the resolvers in
#                           resolv.conf; used only while awg-quick resolves an
#                           Endpoint host name
#
# Each rebuild is a single iptables-restore transaction, so the chain is never
# seen empty while it is being replaced.

CHAIN="${KS_CHAIN:-AWG_KILLSWITCH}"
TUNNEL_IF="${TUNNEL_IF:-wg0}"
RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"

log() {
    echo "--- [killswitch] $1 ---" >&2
}

# LAN networks of one family (4 or 6), space-separated
lan_networks() {
    for net in $(echo "${LAN_NETWORK:-} ${LAN_NETWORK6:-}" | tr ',' ' '); do
        case "$net" in
            *:*) [ "$1" = 6 ] && echo "$net" ;;
            *)   [ "$1" = 4 ] && echo "$net" ;;
        esac
    done
}

protected_networks() {
    if [ "$1" = 6 ]; then
        printf '%s\n' fc00::/7 fe80::/10 ff00::/8
    else
        printf '%s\n' 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16
    fi
}

# Resolvers of one family (4 or 6) from resolv.conf
resolvers() {
    awk -v six="$1" '$1 == "nameserver" && (($2 ~ /:/) == (six == "6")) { print $2 }' "$RESOLV_CONF" 2>/dev/null
}

valid_resolver_address() {
    awk '
        function ipv4(s, a, n, i) {
            n = split(s, a, ".")
            if (n != 4) return 0
            for (i = 1; i <= 4; i++)
                if (a[i] !~ /^[0-9]+$/ || length(a[i]) > 3 || a[i] > 255) return 0
            return 1
        }
        function groups(s, a, n, i) {
            if (s == "") return 0
            n = split(s, a, ":")
            for (i = 1; i <= n; i++)
                if (a[i] !~ /^[[:xdigit:]]+$/ || length(a[i]) > 4) return -100
            return n
        }
        {
            s = $0
            if (s !~ /^[0-9A-Fa-f:.]+$/) exit 1
            if (s ~ /:/) {
                if (s ~ /:::/) exit 1
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
                exit 0
            }
            exit ipv4(s) ? 0 : 1
        }
    ' <<EOF
$1
EOF
}

validate_resolver_config() {
    local found=0 ns
    [ -r "$RESOLV_CONF" ] || {
        log "ERROR: Resolver configuration is not readable"
        return 1
    }
    while IFS= read -r ns; do
        [ -n "$ns" ] || continue
        found=1
        if ! valid_resolver_address "$ns"; then
            log "ERROR: Non-numeric or malformed resolver in resolver configuration"
            return 1
        fi
        case "$ns" in
            127.*|0.0.0.0|::|::1)
                log "ERROR: Loopback/unspecified resolver is not allowed; Docker embedded DNS is unsupported"
                return 1
                ;;
        esac
    done <<EOF
$(awk '$1 == "nameserver" { print $2 }' "$RESOLV_CONF" 2>/dev/null)
EOF
    [ "$found" -eq 1 ] || {
        log "ERROR: No numeric DNS resolver is configured"
        return 1
    }
}

# fwmark of the tunnel's sockets; empty while the tunnel is down
tunnel_mark() {
    m=$(awg show "$TUNNEL_IF" fwmark 2>/dev/null)
    case "$m" in
        '') ;;
        *) printf '%s\n' "$m" | grep -Eq '^(0[xX][[:xdigit:]]+|[0-9]+)$' && echo "$m" ;;
    esac
}

ruleset() {
    fam="$1"
    dns="$2"
    if [ "$fam" = 6 ]; then
        reject=icmp6-adm-prohibited
    else
        reject=icmp-admin-prohibited
    fi

    echo "*filter"
    echo ":$CHAIN - [0:0]"
    echo "-F $CHAIN"
    if [ "$fam" = 4 ]; then
        echo "-A $CHAIN -p udp -d 127.0.0.11 --dport 53 -j REJECT --reject-with $reject"
        echo "-A $CHAIN -p tcp -d 127.0.0.11 --dport 53 -j REJECT --reject-with $reject"
    fi
    for ns in $(resolvers "$fam"); do
        if [ "$dns" = 1 ]; then
            echo "-A $CHAIN -p udp -m owner --uid-owner 65532 -d $ns --dport 53 -j ACCEPT"
            echo "-A $CHAIN -p tcp -m owner --uid-owner 65532 -d $ns --dport 53 -j ACCEPT"
        fi
    done
    echo "-A $CHAIN -o $TUNNEL_IF -p udp --dport 53 -j ACCEPT"
    echo "-A $CHAIN -o $TUNNEL_IF -p tcp --dport 53 -j ACCEPT"
    echo "-A $CHAIN -p udp --dport 53 -j REJECT --reject-with $reject"
    echo "-A $CHAIN -p tcp --dport 53 -j REJECT --reject-with $reject"
    echo "-A $CHAIN -o lo -j ACCEPT"
    for net in $(lan_networks "$fam"); do
        echo "-A $CHAIN -d $net -j ACCEPT"
    done
    for port in 1080 8080; do
        echo "-A $CHAIN -p tcp -m conntrack --ctstate ESTABLISHED --ctdir REPLY --sport $port -j ACCEPT"
    done
    for net in $(protected_networks "$fam"); do
        echo "-A $CHAIN -d $net -j REJECT --reject-with $reject"
    done
    echo "-A $CHAIN -o $TUNNEL_IF -j ACCEPT"
    mark=$(tunnel_mark)
    if [ -n "$mark" ]; then
        echo "-A $CHAIN -p udp -m mark --mark $mark -j ACCEPT"
    fi
    echo "-A $CHAIN -j REJECT --reject-with $reject"
    echo "COMMIT"
}

apply_family() {
    bin=iptables
    if [ "$1" = 6 ]; then
        bin=ip6tables
    fi
    ruleset "$1" "$2" | "$bin-restore" --noflush || return 1
    "$bin" -C OUTPUT -j "$CHAIN" 2>/dev/null || "$bin" -I OUTPUT 1 -j "$CHAIN" || return 1
}

case "${1:-}" in
    apply) DNS=0 ;;
    dns-open) DNS=1 ;;
    *)
        echo "usage: killswitch.sh apply|dns-open" >&2
        exit 2
        ;;
esac

if ! validate_resolver_config; then
    exit 1
fi

if ! apply_family 4 "$DNS"; then
    log "ERROR: IPv4 kill switch could not be applied"
    exit 1
fi

if ! apply_family 6 "$DNS"; then
    if [ -n "$(ip -6 route show default 2>/dev/null)" ]; then
        log "ERROR: IPv6 kill switch could not be applied, but an IPv6 default route exists"
        exit 1
    fi
    log "WARNING: IPv6 kill switch not applied (no IPv6 default route to leak through)"
fi
