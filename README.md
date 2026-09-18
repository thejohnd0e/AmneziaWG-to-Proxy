# AmneziaWG-to-Proxy

[![MIT License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-v2-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Shell](https://img.shields.io/badge/Shell-POSIX%20sh-4EAA25?logo=gnu-bash&logoColor=white)](scripts/)
[![Last Commit](https://img.shields.io/github/last-commit/thejohnd0e/AmneziaWG-to-Proxy)](https://github.com/thejohnd0e/AmneziaWG-to-Proxy/commits/master)

Docker-based proxy bridge that routes traffic through your AmneziaWG tunnel.
Provides SOCKS5 (port 8200) and HTTP (port 9200) proxies with automatic config failover.

## Features

- Speed-tests all configs at startup and connects to the fastest one
- Automatic detection and switching to the next working config
- Rejected configs are moved to `bad_config/` and never retried
- Dual health check endpoints (Google + Cloudflare)
- Manual proxy checker CLI tool
- All tunables configurable via `.env`

## Requirements

- Linux with Docker Engine and Docker Compose v2
- `NET_ADMIN` capability (for WireGuard)

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/thejohnd0e/AmneziaWG-to-Proxy.git
cd AmneziaWG-to-Proxy

# 2. Copy example env
cp .env.example .env

# 3. Place your AmneziaWG config(s) in ./config/
cp /path/to/your-config.conf ./config/

# 4. Build and start
docker compose up -d --build

# 5. Check logs
docker compose logs -f amnezia-proxy
```

Proxies are available at:

- **SOCKS5:** `localhost:8200`
- **HTTP:** `localhost:9200`

## How It Works

```
┌──────────────────────────────────────────────────┐
│  Docker Container                               │
│                                                  │
│  ┌─────────────────┐   ┌──────────────────────┐  │
│  │ failover-manager │   │ entrypoint           │  │
│  │                 │   │                      │  │
│  │ • selects config │   │ • starts proxies     │  │
│  │ • checks health  │   │ • supervises process │  │
│  │ • switches on    │   │                      │  │
│  │   failure        │   │                      │  │
│  └────────┬────────┘   └──────────────────────┘  │
│           │                                      │
│           ▼                                      │
│  ┌─────────────────┐   ┌──────────────────────┐  │
│  │ AmneziaWG (wg0) │──▶│ SOCKS5 :1080        │──┼──▶ Host :8200
│  │                 │──▶│ HTTP/Privoxy :8080   │──┼──▶ Host :9200
│  └─────────────────┘   └──────────────────────┘  │
│                                                  │
│  /configs/*.conf  ← source configs (read)        │
│  /bad_config/     ← rejected configs (moved)     │
└──────────────────────────────────────────────────┘
```

## Config Checker

Manually test configs before deploying:

```bash
chmod +x proxy-checker
./proxy-checker ./config
```

The checker starts its own tunnel, so it can run alongside the failover
container. If the configs being checked share the active WireGuard key, the two
tunnels compete for the WARP session, which may briefly interrupt the live proxy
and occasionally give false results. For a guaranteed-clean run, stop the
container first:

```bash
docker compose down
./proxy-checker ./config
docker compose up -d --force-recreate
```

Output:

```
CONFIG                           STATUS  IP              COUNTRY  CITY     ASN    ORG                LATENCY
server-01.conf                   OK      203.0.113.20    Germany  Frankfurt AS12345 Example GmbH   42 ms
server-02.conf                   BAD     -               -        -        -      -                 timeout

Checked: 2 | Working: 1 | Failed: 1
```

Non-working configs are automatically moved to `bad_config/`.

## Documentation

- [Configuration](docs/CONFIGURATION.md) — all environment variables
- [Failover](docs/FAILOVER.md) — how automatic switching works
- [Proxy Checker](docs/PROXY_CHECKER.md) — manual config testing
- [Troubleshooting](docs/TROUBLESHOOTING.md) — common issues
- [Security](docs/SECURITY.md) — security considerations
- [Third Party](docs/THIRD_PARTY.md) — upstream dependencies

## License

MIT — see [LICENSE](LICENSE).

**Note:** This project uses the upstream `ghcr.io/mainfrezzer/amnezia-bridge` image which has no declared license. See [THIRD_PARTY.md](docs/THIRD_PARTY.md) for details.
