# Automatic Failover

This document describes how automatic config switching works.

## Overview

The failover manager runs as a background process inside the container.
It continuously monitors the active tunnel and switches to the next config when the current one fails.

## Algorithm

```
1. If `FAST_START=1`, try the last-working config first and skip ranking if it passes. Otherwise rank candidates in version-sorted order:
   a. Copy to wg0.conf, awg-quick up wg0
   b. Health check (HTTPS via wg0); record a pending failure if it does not pass
   c. Measure latency (best of 3 probes through wg0)
   d. awg-quick down wg0
2. Rank measured working configs by latency
3. Activate the lowest-latency measured config; with the default `RANK_BUDGET=0`, ranking stops at the first working candidate, which may not be globally fastest
4. Monitoring loop:
   a. Sleep FAILOVER_INTERVAL seconds
   b. Run health check (HTTPS via wg0)
   c. If ok: reset failure counter
   d. If fail: increment counter
   e. If counter >= FAILOVER_FAILURES:
      - Restart the tunnel on the same config (awg-quick down/up, fresh UDP
        source port), up to TUNNEL_RESTARTS times; if it is healthy again,
        keep the config and go back to monitoring
      - If the restarts did not help and this is the only config, keep it in
        config/ and retry later (a server-side outage never leaves the
        container without a config)
      - Otherwise: awg-quick down wg0
       - Keep failed candidates pending until another config is actually active;
         then apply one strike to each failed candidate. After QUARANTINE_AFTER
         committed strikes (kept across container restarts in bad_config/.strikes/)
         move the candidate to bad_config/
      - Pick the next config from the ranked list
      - If the list is exhausted → re-rank the remaining configs
      - If no configs left → unhealthy, periodic retry
```

## Speed Test

When `SPEED_TEST=1`, the manager measures configs during startup ranking:

- Each config is brought up and checked for connectivity.
- Latency is the **best of 3** HTTPS probes through `wg0`, with DNS lookup
  time subtracted so configs are compared by server latency, not resolver speed.
- A failed `awg-quick up` or health probe is inconclusive: it may be a bad
  candidate or a host/network outage. Such failures are kept pending until a
  replacement is actually active. Endpoint DNS failures are skipped without
  adding a strike. If no candidate becomes healthy, config files and existing
  strike counts are preserved for the next retry.
- Once a replacement is active, each failed candidate from that selection cycle
  receives one strike. After `QUARANTINE_AFTER` committed strikes, it is moved to
  `bad_config/`. A config's existing strikes are cleared only after it remains
  healthy for `FAILOVER_FAILURES` consecutive monitoring checks.
- Fast start (`FAST_START=1`): the config that was active last is remembered in
  `bad_config/.last_active`. After a container restart it is tried first and, if
  it passes the health check, the ranking is skipped entirely (the proxy is up
  in seconds). Only when it fails does the full ranking run.
- After `RANK_BUDGET` seconds (default `0`: the first working config wins) the ranking stops as soon as one config works,
  so a long list of dead configs cannot delay the proxy. Untested configs stay
  in `config/` and are tried in the next round.
- The lowest-latency config among the candidates actually measured becomes ACTIVE
  only when the ranking budget allows measuring them all. With default
  `RANK_BUDGET=0`, the first working candidate becomes ACTIVE.

This can make startup slower when `RANK_BUDGET` is positive. Set `SPEED_TEST=0`
to disable latency ranking and try configs in version-sorted name order.

## Health Check Details

The health check sends HTTPS requests through the active WireGuard tunnel (`wg0` interface).
Two independent endpoints are used:

- `https://connectivitycheck.gstatic.com/generate_204`
- `https://cp.cloudflare.com/generate_204`

A round is successful if **any** endpoint answers with a `2xx` status.
A redirect or an error page does not count. All endpoints must fail for the
round to count as a failure.

The Docker healthcheck (`/healthcheck.sh`) checks what clients use: it needs an
active config and a `2xx` answer through **both** the SOCKS5 proxy
(`127.0.0.1:1080`) and the HTTP proxy (`127.0.0.1:8080`). Its timeout is 20
seconds. Increase it if `HEALTH_URLS` has more endpoints or the probe timeout
is raised.

The entrypoint supervises both proxies and restarts one that exits; if the
failover manager exits, the container exits with its status.

This dual-endpoint approach prevents false positives when one service is temporarily unavailable.

## Timing

With default monitoring settings (`FAILOVER_INTERVAL=15`, `FAILOVER_FAILURES=3`):

- A health check runs every 15 seconds
- After 3 consecutive failed health checks (~45 seconds), the manager restarts
  the same tunnel up to `TUNNEL_RESTARTS` times before switching candidates.
- A failed config remains in place until a replacement becomes active; then a
  strike is committed. Quarantine happens only after `QUARANTINE_AFTER` strikes.
- Exact failover time also depends on startup/restart probe timeouts and candidate
  availability; ~45–60 seconds is only a healthy-network estimate.

## Rejected Configs

When a config reaches `QUARANTINE_AFTER` committed strikes:

1. The tunnel is brought down (`awg-quick down wg0`)
2. The config file is copied to `bad_config/`
3. The original is deleted from `config/`
4. The next config is selected

Quarantined configs are excluded from automatic retry until an operator reviews
and restores them to `config/`. A DNS resolution failure alone neither strikes
nor quarantines a config.

### Name Collisions

If a file with the same name already exists in `bad_config/`, a timestamp is appended:

```
server-02.20260918-142530.conf
```

## All Configs Failed

When no working configs remain:

- The container becomes `unhealthy`
- The failover manager periodically scans `config/` for new files
- New configs are automatically picked up and tested
- The proxy ports still accept connections, but every outbound connection is rejected by the kill switch (`scripts/killswitch.sh`) until a working config is found

This is a **fail-closed** design: new outbound traffic leaves through the
tunnel or its marked UDP socket, except for exact destination CIDRs explicitly
listed in `LAN_NETWORK*` and narrow TCP replies to established proxy-client
connections. Private/link-local destinations are blocked by default.

## State Diagram

```
                ┌──────────┐
                │  PENDING  │
                └────┬─────┘
                     │
                     ▼
              ┌──────────────┐
              │   TESTING    │◀──────────────┐
              └──────┬───────┘               │
                     │                       │
            ┌────────┴────────┐              │
            │  Health OK      │              │
            ▼                 ▼              │
    ┌──────────────┐  ┌──────────────┐       │
    │    ACTIVE    │  │    FAILED    │───────┘
    └──────┬───────┘  └──────┬───────┘
           │                  │
           │          threshold reached
           │                  │
           │                  ▼
           │          ┌──────────────┐
           │          │  BAD_CONFIG  │
           │          └──────────────┘
           │
           │  health fails
           ▼
    ┌──────────────┐
    │  RECOVERY    │
    └──────────────┘
```

## Failover with Multiple Configs

Example with 3 configs:

| Time | Event | Active |
|---|---|---|
| 0:00 | server-01.conf started | server-01.conf |
| 0:00 | Health check passes | server-01.conf |
| 5:00 | server-01.conf health fails | server-01.conf |
| 5:15 | 1st failure counted | server-01.conf |
| 5:30 | 2nd failure counted | server-01.conf |
| 5:45 | 3rd failure → switch | server-02.conf |
| 5:45 | server-02.conf health passes | server-02.conf |
| 10:00 | server-02.conf health fails | server-02.conf |
| ... | ... | ... |

Rejected configs in `bad_config/`:
```
bad_config/server-01.conf
```

## Environment Variables

| Variable | Default | Effect |
|---|---|---|
| `FAILOVER_INTERVAL` | `15` | Seconds between health checks |
| `FAILOVER_FAILURES` | `3` | Failures before switching |
| `FAILOVER_TIMEOUT` | `8` | HTTPS probe timeout |
| `HEALTH_URLS` | Google + Cloudflare | Health check endpoints |
| `SPEED_TEST` | `1` | Rank configs by latency at startup |
| `SPEED_TEST_URL` | first `HEALTH_URLS` entry | URL used for latency probes |

See [CONFIGURATION.md](CONFIGURATION.md) for full details.
