#!/bin/sh
# Install only explicitly requested bypass and proxy-client return routes.

ROUTES_FILE="${TMPDIR:-/tmp}/proxy-routes.$$.state"
umask 077
set -f
: > "$ROUTES_FILE" || exit 1

rollback_routes() {
    local family network gateway
    [ -f "$ROUTES_FILE" ] || return 0
    while IFS=' ' read -r family network gateway; do
        [ -n "$network" ] || continue
        if [ "$family" = 6 ]; then
            ip -6 route del "$network" via "$gateway" dev eth0 2>/dev/null || true
        else
            ip route del "$network" via "$gateway" dev eth0 2>/dev/null || true
        fi
    done < "$ROUTES_FILE"
}

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        rollback_routes
    fi
    rm -f "$ROUTES_FILE"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

install_family() {
    family="$1"
    networks="$2"
    gateway="$3"
    [ -n "$networks" ] || return 0
    if [ -z "$gateway" ]; then
        echo "ERROR: requested IPv$family routes but no Docker gateway is available" >&2
        return 1
    fi

    networks=$(printf '%s' "$networks" | tr ',' ' ')
    for network in $networks; do
        case "$family:$network" in
            4:*:*) echo "ERROR: IPv6 CIDR in IPv4 route list: $network" >&2; return 1 ;;
            4:*)
                if ! printf '%s\n' "$network" | awk -F/ '
                    NF != 2 { exit 1 }
                    {
                        n = split($1, octets, ".")
                        if (n != 4 || $2 !~ /^[0-9]+$/ || $2 > 32) exit 1
                        for (i = 1; i <= 4; i++)
                            if (octets[i] !~ /^[0-9]+$/ || octets[i] > 255) exit 1
                    }
                '; then
                    echo "ERROR: invalid IPv4 CIDR: $network" >&2
                    return 1
                fi
                printf '%s %s %s\n' "$family" "$network" "$gateway" >> "$ROUTES_FILE" || return 1
                ip route replace "$network" via "$gateway" dev eth0 onlink || return 1
                ;;
            6:*)
                case "$network" in
                    *:*/[0-9]*) ;;
                    *) echo "ERROR: invalid IPv6 CIDR: $network" >&2; return 1 ;;
                esac
                printf '%s %s %s\n' "$family" "$network" "$gateway" >> "$ROUTES_FILE" || return 1
                ip -6 route replace "$network" via "$gateway" dev eth0 onlink || return 1
                ;;
        esac
    done
}

install_family 4 "${LAN_NETWORK:-} ${PROXY_CLIENT_NETWORKS:-}" "${IP4GATEWAY:-}" || exit 1
install_family 6 "${LAN_NETWORK6:-} ${PROXY_CLIENT_NETWORKS6:-}" "${IP6GATEWAY:-}" || exit 1
