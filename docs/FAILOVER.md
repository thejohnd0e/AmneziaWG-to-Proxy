# Automatic Failover

This document describes how automatic config switching works.

## Overview

The failover manager runs as a background process inside the container.
It continuously monitors the active tunnel and switches to the next config when the current one fails.

## Algorithm

```
1. Speed-test every *.conf in /configs:
   a. Copy to wg0.conf, awg-quick up wg0
   b. Health check (HTTPS via wg0); on failure after retries → a strike (bad_config/ after QUARANTINE_AFTER strikes)
   c. Measure latency (best of 3 probes through wg0)
   d. awg-quick down wg0
2. Rank working configs by latency, fastest first
3. Activate the fastest config and mark it ACTIVE
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
      - Give the failed config a strike; after QUARANTINE_AFTER strikes (kept
        across container restarts in bad_config/.strikes/) move it to bad_config/
      - Pick the next config from the ranked list
      - If the list is exhausted → re-rank the remaining configs
      - If no configs left → unhealthy, periodic retry
```

## Speed Test

At startup the manager measures every config before connecting:

- Each config is brought up and checked for connectivity.
- Latency is the **best of 3** HTTPS probes through `wg0`, with DNS lookup
  time subtracted so configs are compared by server latency, not resolver speed.
- Configs that cannot start are moved to `bad_config/` at once. Configs that
  stay unreachable get a strike and are moved after `QUARANTINE_AFTER` strikes,
  so one network blip does not cost a working config.
- Fast start (`FAST_START=1`): the config that was active last is remembered in
  `bad_config/.last_active`. After a container restart it is tried first and, if
  it passes the health check, the ranking is skipped entirely (the proxy is up
  in seconds). Only when it fails does the full ranking run.
- After `RANK_BUDGET` seconds the ranking stops as soon as one config works,
  so a long list of dead configs cannot delay the proxy. Untested configs stay
  in `config/` and are tried in the next round.
- The fastest working config becomes ACTIVE; the rest are kept ranked for failover.

This makes startup slower (roughly a few seconds per config) but selects the
lowest-latency server. Set `SPEED_TEST=0` to disable ranking and use the
first config by name instead.

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
| `SPEED_TEST` | `1` | Rank configs by latency at startup |
| `SPEED_TEST_URL` | first `HEALTH_URLS` entry | URL used for latency probes |

See [CONFIGURATION.md](CONFIGURATION.md) for full details.
