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

echo "PASS: safe proxy defaults and build-context exclusions"
