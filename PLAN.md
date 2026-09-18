# AmneziaWG-to-Proxy — Development Plan

This document describes the full implementation plan for the public GitHub project.
All documentation, scripts, and UI are in English.

---

## 1. Project Overview

A Docker-based AmneziaWG-to-SOCKS5/HTTP proxy bridge with:

- Automatic config failover (bad configs are never retried)
- Manual proxy checker CLI tool
- Full English documentation

### Key Design Decisions

| Decision | Value | Reason |
|---|---|---|
| Failover direction | Sequential, not random | Avoid retrying a known-bad config |
| Failed config fate | Move to `bad_config/` permanently | Prevents silent reuse |
| Manual checker behavior | Always move bad configs | Per user request |
| GeoIP provider | Primary: `https://ipwho.is/` Fallback: `https://www.cloudflare.com/cdn-cgi/trace` | No API key required |
| Health endpoints | `https://connectivitycheck.gstatic.com/generate_204` + `https://cp.cloudflare.com/generate_204` | Dual-endpoint for resilience |
| License | MIT (our code only) | Open source permissive |
| GHCR publishing | Source only, no auto-publish | Upstream has no license declaration |
| Build method | Local `docker compose build` | Safe default |
| Run environment | Linux/Debian | Primary target |
| Check failure fate | Move to `bad_config/` always | Per user request |

---

## 2. Repository Structure

```
.
├── PLAN.md
├── README.md
├── LICENSE
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── .gitignore
├── proxy-checker                    # CLI wrapper
├── scripts/
│   ├── entrypoint.sh               # Container entrypoint
│   ├── failover-manager.sh          # Background failover supervisor
│   ├── check-tunnel.sh             # Shared tunnel health check
│   └── proxy-checker.sh            # Proxy checker logic (used by proxy-checker CLI)
├── docs/
│   ├── CONFIGURATION.md
│   ├── FAILOVER.md
│   ├── PROXY_CHECKER.md
│   ├── TROUBLESHOOTING.md
│   ├── SECURITY.md
│   └── THIRD_PARTY.md
├── config/                          # User AmneziaWG .conf files (gitignored)
└── bad_config/                      # Rejected configs (gitignored)
```

---

## 3. Files to Create / Modify

### 3.1 `.gitignore`

```gitignore
.env
config/*.conf
bad_config/*.conf
```

### 3.2 `.env.example`

```dotenv
# === Failover tuning ===
FAILOVER_INTERVAL=15          # Seconds between health checks
FAILOVER_FAILURES=3           # Consecutive failures before switching
FAILOVER_TIMEOUT=8            # Max seconds per HTTPS probe

# === Health check ===
HEALTH_URLS=https://connectivitycheck.gstatic.com/generate_204,https://cp.cloudflare.com/generate_204
HEALTH_URL_CHECK=             # Optional: override for upstream healthcheck ping target

# === Proxy bind ===
PROXY_BIND_ADDRESS=0.0.0.0    # Bind address for SOCKS5/HTTP ports

# === Upstream defaults (kept for reference) ===
LAN_NETWORK=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,172.17.0.0/16,169.254.0.0/16
LAN_NETWORK6=fd00::/8,fe80::/10
HTTPPORT=8080
ENABLE_RANDOM=0
# DISABLE_TUNNEL_MODE=1
```

### 3.3 `LICENSE`

MIT license, copyright holder: `thejohnd0e`.

### 3.4 `Dockerfile`

```dockerfile
FROM ghcr.io/mainfrezzer/amnezia-bridge:latest

COPY scripts /scripts
COPY scripts/check-tunnel.sh /check-tunnel.sh
COPY scripts/failover-manager.sh /failover-manager.sh
COPY scripts/entrypoint.sh /entrypoint.sh

RUN chmod +x /check-tunnel.sh /failover-manager.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

Rationale: thin overlay, no rebuild of AmneziaWG internals. Healthcheck from upstream is replaced by our entrypoint-driven failover manager.

### 3.5 `docker-compose.yml` (updated)

```yaml
services:
  amnezia-proxy:
    build:
      context: .
    image: amnezia-bridge-failover:local
    container_name: AmneziaWG-to-Proxy
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - ./config:/configs
      - ./bad_config:/bad_config
    ports:
      - "${PROXY_BIND_ADDRESS:-0.0.0.0}:8200:1080/tcp"
      - "${PROXY_BIND_ADDRESS:-0.0.0.0}:9200:8080/tcp"
    environment:
      FAILOVER_INTERVAL: ${FAILOVER_INTERVAL:-15}
      FAILOVER_FAILURES: ${FAILOVER_FAILURES:-3}
      FAILOVER_TIMEOUT: ${FAILOVER_TIMEOUT:-8}
      HEALTH_URLS: ${HEALTH_URLS:-https://connectivitycheck.gstatic.com/generate_204,https://cp.cloudflare.com/generate_204}
      LAN_NETWORK: ${LAN_NETWORK:-192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,172.17.0.0/16,169.254.0.0/16}
      LAN_NETWORK6: ${LAN_NETWORK6:-fd00::/8,fe80::/10}
      HTTPPORT: ${HTTPPORT:-8080}
      ENABLE_RANDOM: "0"
      # DISABLE_TUNNEL_MODE: ${DISABLE_TUNNEL_MODE:-}
      # HEALTH_URL_CHECK: ${HEALTH_URL_CHECK:-}
```

### 3.6 `scripts/check-tunnel.sh` (shared health check)

Core logic shared by both failover-manager and proxy-checker.

```
Input:  FAILOVER_TIMEOUT, HEALTH_URLS
Output: exit 0 (healthy) or exit 1 (unhealthy)

Algorithm:
  1. For each URL in HEALTH_URLS (comma-separated):
     a. curl --interface wg0 --fail --silent --max-time $FAILOVER_TIMEOUT $URL
     b. If any succeeds → return 0
  2. All failed → return 1
```

### 3.7 `scripts/failover-manager.sh` (background supervisor)

```
Input:  /configs/*.conf, /bad_config/, FAILOVER_*
Output: manages wg0.conf inside the container

Algorithm:
  1. List all *.conf in /configs (excluding wg0.conf if present)
  2. If zero configs found → echo status, sleep 60, retry
  3. Sort files with sort -V, pick first
  4. Copy to /etc/amnezia/amneziawg/wg0.conf
  5. awg-quick up wg0
  6. check-tunnel.sh → if fail, try next config
  7. Start monitoring loop:
     a. sleep FAILOVER_INTERVAL
     b. check-tunnel.sh
     c. If success → reset failure counter
     d. If fail → increment counter
     e. If counter >= FAILOVER_FAILURES:
        - awg-quick down wg0
        - Move failed config to /bad_config/ (copy + rm)
        - Pick next config
        - If no configs left → unhealthy, periodic retry
     e2. Sleep remaining interval
  8. Maintain /tmp/active_config marker
```

### 3.8 `scripts/entrypoint.sh`

```
1. Start failover-manager.sh in background
2. Start microsocks (SOCKS5 on port 1080)
3. Start privoxy (HTTP on port $HTTPPORT)
4. Wait for failover-manager to establish first tunnel
5. Maintain process supervision (trap SIGTERM for cleanup)
```

### 3.9 `scripts/proxy-checker.sh` (checker logic)

```
Input:  directory path, optional --bad-dir
Output: formatted table + moved files

Algorithm:
  1. Validate input directory
  2. Create bad_config/ if missing
  3. For each *.conf in input directory:
     a. Create temp workspace
     b. Copy config to wg0.conf
     c. awg-quick up wg0
     d. Record tunnel startup time
     e. check-tunnel.sh → record status
     f. curl --interface wg0 https://ipwho.is/ → extract IP, country, city, ASN, provider
     g. curl --interface wg0 three times to health endpoint → record latency, compute median
     h. awg-quick down wg0
     i. If unhealthy → move to bad_config/
  4. Print summary table
  5. Exit codes: 0 = all OK, 1 = some moved, 2 = checker error
```

### 3.10 `proxy-checker` (CLI wrapper)

```bash
#!/bin/bash
# Run the proxy checker in an isolated Docker container
# Usage: ./proxy-checker /path/to/config [--bad-dir /path/to/bad_config]

docker run --rm \
  --cap-add NET_ADMIN \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -v "$1":/check_config:ro \
  -v "${2:-../bad_config}":/bad_config \
  --entrypoint /scripts/proxy-checker.sh \
  amnezia-bridge-failover:local /check_config "$@"
```

---

## 4. Documentation Plan

### 4.1 `README.md`

- Project overview and purpose
- Requirements (Linux, Docker, Docker Compose)
- Quick Start (3 commands)
- How it works (architecture diagram in text)
- Links to detailed docs

### 4.2 `docs/CONFIGURATION.md`

- All environment variables with descriptions, defaults, units
- How to tune failover intervals
- Proxy bind address security
- LAN_NETWORK and LAN_NETWORK6 usage
- Updating the upstream base image

### 4.3 `docs/FAILOVER.md`

- Failover algorithm in detail
- State diagram: config → checking → active → failed → bad_config
- Health check flow (dual HTTPS endpoints)
- Timing: how long until failover happens
- What happens when all configs fail
- How to restore a config from bad_config
- How cooldown works

### 4.4 `docs/PROXY_CHECKER.md`

- Installation and first run
- CLI usage with examples
- Output format explanation
- Exit codes
- Running in cron
- Differences from the automatic failover

### 4.5 `docs/TROUBLESHOOTING.md`

- Container won't start: missing config directory
- Tunnel fails: invalid .conf file
- All configs rejected: how to investigate
- GeoIP service unavailable:不影响 tunnel health
- Docker permission errors
- Port conflicts
- awg-quick failures

### 4.6 `docs/SECURITY.md`

- .conf files contain private keys — never commit
- Proxies have no authentication
- PROXY_BIND_ADDRESS risk
- Never route traffic directly without VPN
- GeoIP endpoint reveals external IP
- Limit network exposure with firewall

### 4.7 `docs/THIRD_PARTY.md`

- Upstream: Mainfrezzer/amnezia-bridge (no license)
- Base image: ghcr.io/mainfrezzer/amnezia-bridge
- AmneziaWG: amnezia-vpn/amneziawg-go + amnezia-vpn/amneziawg-tools
- microsocks: rofl0r/microsocks
- GeoIP: ipwho.is (primary), Cloudflare (fallback)
- License implications for our code vs upstream layers

---

## 5. Implementation Order

| Step | Action | Files |
|---|---|---|
| 1 | Write plan | PLAN.md |
| 2 | Create gitignore | .gitignore |
| 3 | Create env template | .env.example |
| 4 | Create license | LICENSE |
| 5 | Create Dockerfile | Dockerfile |
| 6 | Write check-tunnel.sh | scripts/check-tunnel.sh |
| 7 | Write failover-manager.sh | scripts/failover-manager.sh |
| 8 | Write entrypoint.sh | scripts/entrypoint.sh |
| 9 | Write proxy-checker.sh | scripts/proxy-checker.sh |
| 10 | Write CLI wrapper | proxy-checker |
| 11 | Update docker-compose.yml | docker-compose.yml |
| 12 | Create bad_config dir marker | bad_config/.gitkeep |
| 13 | Write README.md | README.md |
| 14 | Write docs | docs/*.md |
| 15 | Verify: docker compose config --quiet | (validation) |

---

## 6. Verification Checklist

```bash
docker compose config --quiet
docker compose build
docker compose up -d
docker compose ps
docker compose logs amnezia-proxy
./proxy-checker --help
```

Scenarios to test:

- Single working config
- First config bad, second good
- All configs bad
- Config fails after initial success
- New config added while config dir is empty
- Name collision in bad_config
- One health endpoint down
- GeoIP service unavailable
- Invalid environment variables
- Container killed during config move
