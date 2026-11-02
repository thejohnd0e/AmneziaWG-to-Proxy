# Configuration

All settings are controlled via environment variables in `.env`.

## Config format

`config/*.conf` may be AmneziaWG 1.0 (`Jc/Jmin/Jmax`, `S1/S2`, `H1-H4`), 1.5 (adds `I1-I5`) or 2.0 (adds `S3/S4` and `H1-H4` as ranges like `100000-200000`). Nothing has to be set: the bundled `amneziawg-go` and `awg-quick` apply whatever the file contains, and configs of different versions can be mixed in one folder. Checked with a real handshake and ping between two containers of the image for each version. Both ends must use the same `S1-S4` and `H1-H4`; `Jc/Jmin/Jmax` and `I1-I5` are client-side only.

The base image `ghcr.io/mainfrezzer/amnezia-bridge` builds `amneziawg-go` from upstream `master` at its build time. If a future protocol field is rejected (`awg-quick` fails with a parse error), rebuild the image against a newer base: `docker compose build --pull --no-cache`.

## WARP config generator

`scripts/warp-gen.sh [count] [proxy]` (inside the container: `/scripts/warp-gen.sh 10`) registers `count` free anonymous Cloudflare WARP devices and writes `warp-<id>.conf` files. Cloudflare's end is plain WireGuard, so the AmneziaWG fields are the client-only ones: `Jc/Jmin/Jmax` junk packets and a QUIC-like `I1` signature (random per config), with `S1=S2=0` and `H1-H4=1-4`. The private key is generated on the machine that runs the script.

| Variable / argument | Default | Description |
|---|---|---|
| `count` (1st argument) | `1` | Number of registrations |
| `proxy` (2nd argument) or `WARP_PROXY` | *(none)* | Optional HTTP proxy used only for the registration, e.g. the proxy of a running WARP container (`http://192.168.0.12:9210`), so that it leaves through Cloudflare, not from your own address. Not needed inside a running container (its traffic goes through the active tunnel) |
| `WARP_OUT` | `/configs` | Where the configs are written |
| `WARP_ENDPOINT` | `162.159.192.7:4500` | Cloudflare endpoint written into the configs |
| `WARP_PAUSE` | `3` | Seconds between registrations (rate limits) |
| `WARP_VERIFY` | `15` | Seconds to wait for a handshake on a throwaway interface (no routes, the running tunnel is not touched); a config that gets none is discarded. `0` = do not check. A working WARP config answers within 1-6 s |

The script never registers from the real address: it needs a proxy or an active `wg0` tunnel and refuses otherwise, and it creates at most 10 configs per run. The API is unofficial and may change or limit registrations from one address (HTTP 429 after about 10 in a row: the script stops, try again later). Do not generate hundreds at once.

## Failover Settings

| Variable | Default | Description |
|---|---|---|
| `FAILOVER_INTERVAL` | `15` | Seconds between health checks |
| `FAILOVER_FAILURES` | `3` | Consecutive failures before the tunnel is restarted / the config is switched |
| `TUNNEL_RESTARTS` | `2` | Tunnel restarts on the same config before it gets a strike (`0` = no restarts) |
| `QUARANTINE_AFTER` | `3` | Failed selection cycles committed only after another config becomes active, before moving a config to `bad_config/` |
| `FAST_START` | `1` | After a restart, try the last working config first (remembered in `bad_config/.last_active`) and skip the ranking if it works; `0` = always rank |
| `RANK_BUDGET` | `0` | Seconds after which the startup ranking stops once one config works (`0` = the first working config wins); untested configs stay in `config/` for the next round |
| `STARTUP_CHECKS` | `1` | Health checks per config at startup; a dead config costs one check, not `FAILOVER_FAILURES` |
| `FAILOVER_TIMEOUT` | `8` | Max seconds per HTTPS probe of the monitoring loop; a lower value (e.g. `3`) notices a stalled tunnel sooner |
| `STARTUP_TIMEOUT` | `8` | Max seconds per probe at startup, ranking and after a tunnel restart (the first handshake of a tunnel can be slow); independent of `FAILOVER_TIMEOUT` |
| `AWG_UP_TIMEOUT` | `30` | Max seconds for `awg-quick up`; timed-out candidates remain in `config/` |
| `SPEED_TEST` | `1` | Rank configs at startup; with default `RANK_BUDGET=0`, the first working config wins, not necessarily the globally fastest |
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
| `PROXY_BIND_ADDRESS` | `127.0.0.1` | Host bind address for proxy ports; use a trusted interface explicitly for LAN access |
| `HTTPPORT` | `8080` | Internal HTTP proxy port (Privoxy) |

## Network Settings

| Variable | Default | Description |
|---|---|---|
| `LAN_NETWORK` | *(empty)* | Exact IPv4 destination CIDRs the proxy may reach outside the tunnel |
| `LAN_NETWORK6` | *(empty)* | Exact IPv6 destination CIDRs the proxy may reach outside the tunnel |
| `PROXY_CLIENT_NETWORKS` | *(empty)* | IPv4 client CIDRs that need return routes; does not allow new proxy connections to those clients |
| `PROXY_CLIENT_NETWORKS6` | *(empty)* | IPv6 client CIDRs that need return routes; does not allow new proxy connections to those clients |
| `DISABLE_TUNNEL_MODE` | *(empty)* | Set to any value to disable full-tunnel enforcement |

Private and link-local destinations (including `169.254.0.0/16`) are blocked by
default, even when the tunnel is up. Add only a narrow `LAN_NETWORK` CIDR for a
destination the proxy genuinely needs. Such destinations bypass the VPN. The
`PROXY_CLIENT_NETWORKS*` lists create return routes only; replies to established
TCP connections on the SOCKS/HTTP listener ports are allowed, but they do not
authorize new proxy requests to the client network.

## Upstream Settings

| Variable | Default | Description |
|---|---|---|
| `ENABLE_RANDOM` | `0` | Must be `0` — random selection is incompatible with failover |

## Example `.env`

```dotenv
FAILOVER_INTERVAL=15
FAILOVER_FAILURES=3
TUNNEL_RESTARTS=2
QUARANTINE_AFTER=3
RANK_BUDGET=0
STARTUP_CHECKS=1
FAST_START=1
FAILOVER_TIMEOUT=8
SPEED_TEST=1
DNS_PRIMARY=1.1.1.1
DNS_SECONDARY=1.0.0.1
PROXY_BIND_ADDRESS=127.0.0.1
LAN_NETWORK=192.168.1.0/24
PROXY_CLIENT_NETWORKS=192.168.1.0/24
```

The example CIDR is intentionally narrow; keep `LAN_NETWORK` empty unless the
proxy must initiate connections to a specific LAN destination. Set
`PROXY_CLIENT_NETWORKS` only when clients outside Docker's directly connected
subnet need an explicit return route.

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
