#!/bin/sh

set -eu

IMAGE="${IMAGE:-amnezia-bridge-failover:local}"
command -v docker > /dev/null 2>&1 || {
    echo "FAIL: docker is required for the image smoke test" >&2
    exit 1
}

docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
    for path in \
        /entrypoint.sh \
        /failover-manager.sh \
        /killswitch.sh \
        /check-tunnel.sh \
        /ensure-tun.sh \
        /proxy-routes.sh \
        /resolve-endpoint.sh; do
        test -x "$path" || { echo "FAIL: missing executable $path" >&2; exit 1; }
    done

    for path in \
        /entrypoint.sh:/scripts/entrypoint.sh \
        /failover-manager.sh:/scripts/failover-manager.sh \
        /killswitch.sh:/scripts/killswitch.sh \
        /check-tunnel.sh:/scripts/check-tunnel.sh \
        /ensure-tun.sh:/scripts/ensure-tun.sh \
        /proxy-routes.sh:/scripts/proxy-routes.sh \
        /resolve-endpoint.sh:/scripts/resolve-endpoint.sh; do
        link=${path%%:*}
        target=${path#*:}
        test "$(readlink "$link")" = "$target" \
            || { echo "FAIL: $link must point to $target" >&2; exit 1; }
    done

    for utility in timeout dig su-exec curl jq awg-quick privoxy; do
        command -v "$utility" > /dev/null 2>&1 \
            || { echo "FAIL: required utility is missing: $utility" >&2; exit 1; }
    done
    test -x /microsocks || { echo "FAIL: /microsocks is missing" >&2; exit 1; }
    test "$(id -u endpoint-resolver)" = 65532 \
        || { echo "FAIL: endpoint-resolver does not have UID 65532" >&2; exit 1; }
    test "$(su-exec 65532:65532 id -u)" = 65532 \
        || { echo "FAIL: su-exec did not switch to UID 65532" >&2; exit 1; }
    echo "PASS: image scripts, symlinks, tools and resolver UID are present"
'
