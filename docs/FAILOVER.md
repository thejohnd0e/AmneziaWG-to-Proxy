# Automatic Failover

This document describes how automatic config switching works.

## Overview

The failover manager runs as a background process inside the container.
It continuously monitors the active tunnel and switches to the next config when the current one fails.

## Algorithm

```
1. List all *.conf in /configs (sorted by version)
2. Pick the first file
3. Copy to wg0.conf
4. awg-quick up wg0
5. Initial health check (HTTPS via wg0)
   → If fail: move to bad_config/, try next
   → If ok: mark as ACTIVE
6. Monitoring loop:
   a. Sleep FAILOVER_INTERVAL seconds
   b. Run health check (HTTPS via wg0)
   c. If ok: reset failure counter
   d. If fail: increment counter
   e. If counter >= FAILOVER_FAILURES:
      - awg-quick down wg0
      - Move failed config to bad_config/
      - Pick next config
      - If no configs left → unhealthy, periodic retry
```

## Health Check Details

The health check sends HTTPS requests through the active WireGuard tunnel (`wg0` interface).
Two independent endpoints are used:

- `https://connectivitycheck.gstatic.com/generate_204`
- `https://cp.cloudflare.com/generate_204`

A round is successful if **any** endpoint responds.
Both must fail for the round to count as a failure.

This dual-endpoint approach prevents false positives when one service is temporarily unavailable.

## Timing

With default settings (`FAILOVER_INTERVAL=15`, `FAILOVER_FAILURES=3`):

- A health check runs every 15 seconds
- After 3 consecutive failures (~45 seconds), the config is rejected
- The next config is tested immediately
- Total time to failover: ~45–60 seconds

## Rejected Configs

When a config is rejected:

1. The tunnel is brought down (`awg-quick down wg0`)
2. The config file is copied to `bad_config/`
3. The original is deleted from `config/`
4. The next config is selected

Rejected configs are **permanently excluded** from automatic retry.
To restore a rejected config, manually move it back to `config/`.

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
- The proxy ports will not serve traffic until a working config is found

This is a **fail-closed** design: traffic never leaks outside the VPN.

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

See [CONFIGURATION.md](CONFIGURATION.md) for full details.
