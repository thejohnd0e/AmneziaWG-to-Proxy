# Configuration

All settings are controlled via environment variables in `.env`.

## Failover Settings

| Variable | Default | Description |
|---|---|---|
| `FAILOVER_INTERVAL` | `15` | Seconds between health checks |
| `FAILOVER_FAILURES` | `3` | Consecutive failures before switching config |
| `FAILOVER_TIMEOUT` | `8` | Max seconds per HTTPS probe |
| `SPEED_TEST` | `1` | Speed-test configs at startup and connect to the fastest |
| `SPEED_TEST_URL` | *(first `HEALTH_URLS` entry)* | URL used for latency probes |

## Health Check

| Variable | Default | Description |
|---|---|---|
| `HEALTH_URLS` | `https://connectivitycheck.gstatic.com/generate_204,https://cp.cloudflare.com/generate_204` | Comma-separated HTTPS URLs for tunnel health check |
| `HEALTH_URL_CHECK` | *(empty)* | Override for upstream healthcheck ping target |

## DNS

| Variable | Default | Description |
|---|---|---|
| `DNS_PRIMARY` | `1.1.1.1` | Primary resolver used inside the container |
| `DNS_SECONDARY` | `1.0.0.1` | Secondary resolver |

Public resolvers are used because a host or router DNS may sinkhole domains to
unreachable addresses (e.g. `198.18.0.0/15`), which makes the proxy time out.
The same resolvers are used by the config checker.

## Proxy Settings

| Variable | Default | Description |
|---|---|---|
| `PROXY_BIND_ADDRESS` | `0.0.0.0` | Bind address for exposed proxy ports |
| `HTTPPORT` | `8080` | Internal HTTP proxy port (Privoxy) |

## Network Settings

| Variable | Default | Description |
|---|---|---|
| `LAN_NETWORK` | `192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,172.17.0.0/16,169.254.0.0/16` | IPv4 ranges to bypass the tunnel |
| `LAN_NETWORK6` | `fd00::/8,fe80::/10` | IPv6 ranges to bypass the tunnel |
| `DISABLE_TUNNEL_MODE` | *(empty)* | Set to any value to disable full-tunnel enforcement |

## Upstream Settings

| Variable | Default | Description |
|---|---|---|
| `ENABLE_RANDOM` | `0` | Must be `0` — random selection is incompatible with failover |

## Example `.env`

```dotenv
FAILOVER_INTERVAL=15
FAILOVER_FAILURES=3
FAILOVER_TIMEOUT=8
SPEED_TEST=1
DNS_PRIMARY=1.1.1.1
DNS_SECONDARY=1.0.0.1
PROXY_BIND_ADDRESS=127.0.0.1
LAN_NETWORK=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12
```

## Changing Settings

After editing `.env`:

```bash
docker compose up -d --force-recreate
```

## Updating the Base Image

```bash
docker compose build --no-cache
docker compose up -d --force-recreate
```

This pulls the latest upstream `ghcr.io/mainfrezzer/amnezia-bridge:latest` and rebuilds the overlay.
