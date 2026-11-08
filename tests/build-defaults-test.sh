#!/bin/sh

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$TEST_DIR")

grep -Fq '"${PROXY_BIND_ADDRESS:-127.0.0.1}:8200:1080/tcp"' "$PROJECT_DIR/docker-compose.yml" \
    || { echo "FAIL: SOCKS5 port does not default to loopback" >&2; exit 1; }
grep -Fq '"${PROXY_BIND_ADDRESS:-127.0.0.1}:9200:8080/tcp"' "$PROJECT_DIR/docker-compose.yml" \
    || { echo "FAIL: HTTP port does not default to loopback" >&2; exit 1; }

grep -Eq '^PROXY_BIND_ADDRESS=127\.0\.0\.1([[:space:]]|$)' "$PROJECT_DIR/.env.example" \
    || { echo "FAIL: .env.example does not default to loopback" >&2; exit 1; }

ignore_file="$PROJECT_DIR/.dockerignore"
[ -f "$ignore_file" ] || { echo "FAIL: .dockerignore is missing" >&2; exit 1; }
for path in config/ bad_config/ .env .git/; do
    grep -Fxq "$path" "$ignore_file" \
        || { echo "FAIL: .dockerignore does not exclude $path" >&2; exit 1; }
done
grep -Fxq '!.env.example' "$ignore_file" \
    || { echo "FAIL: .dockerignore must retain .env.example" >&2; exit 1; }

grep -Eq '^    network_mode: bridge[[:space:]]*$' "$PROJECT_DIR/docker-compose.yml" \
    || { echo "FAIL: Compose must use standard bridge to avoid Docker embedded DNS" >&2; exit 1; }
grep -Fq '${DNS_PRIMARY:-1.1.1.1}' "$PROJECT_DIR/docker-compose.yml" \
    || { echo "FAIL: primary numeric resolver is not configured" >&2; exit 1; }
grep -Fq '${DNS_SECONDARY:-1.0.0.1}' "$PROJECT_DIR/docker-compose.yml" \
    || { echo "FAIL: secondary numeric resolver is not configured" >&2; exit 1; }
if grep -Eq '^[[:space:]]+networks:' "$PROJECT_DIR/docker-compose.yml"; then
    echo "FAIL: service-specific network would re-enable Docker embedded DNS" >&2
    exit 1
fi
grep -Fq 'ghcr.io/mainfrezzer/amnezia-bridge@sha256:fcfa9ae5f361e257e3451a37730c0886b7c1c2f9664b5dd7021c85201c90dc31' "$PROJECT_DIR/Dockerfile" \
    || { echo "FAIL: upstream image must use the verified OCI index digest" >&2; exit 1; }

# Every documented .env setting must reach Compose, or it is silently ignored.
for key in $(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$PROJECT_DIR/.env.example"); do
    grep -Fq "\${$key:-" "$PROJECT_DIR/docker-compose.yml" \
        || grep -Fq "\${$key-" "$PROJECT_DIR/docker-compose.yml" \
        || { echo "FAIL: .env.example sets $key but docker-compose.yml never reads it" >&2; exit 1; }
done
if grep -Eq '^[[:space:]]+HTTPPORT:' "$PROJECT_DIR/docker-compose.yml"; then
    echo "FAIL: HTTPPORT must stay fixed; ports and the kill switch assume 8080" >&2
    exit 1
fi

echo "PASS: safe proxy defaults, isolated build context and direct numeric DNS"
