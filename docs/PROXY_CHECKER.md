# Proxy Checker

Manual CLI tool for testing AmneziaWG configs before deploying them.

## Usage

```bash
./proxy-checker <config_dir> [--bad-dir <bad_config_dir>]
```

> **Important:** stop the running container before checking:
>
> ```bash
> docker compose down
> ./proxy-checker ./config
> docker compose up -d --force-recreate
> ```
>
> The checker brings up its own `wg0` using the same configs. Running it
> alongside the automatic failover container makes both tunnels use the same
> WireGuard keys, so the peer endpoint flaps between them and healthy configs
> can be misreported as `BAD`.

## Examples

```bash
# Check configs in ./config, reject bad ones to ./bad_config/
./proxy-checker ./config

# Check configs, move bad ones to a custom directory
./proxy-checker ./config --bad-dir /tmp/rejected

# Check configs from an absolute path
./proxy-checker /etc/amnezia/amneziawg
```

## First Run

On first run, the checker builds a Docker image (takes ~30 seconds):

```bash
$ ./proxy-checker ./config
--- Building image (first run) ---
[+] Building 25.3s (8/8) FINISHED
--- Checking configs in: /home/user/project/config ---
--- Bad configs will move to: /home/user/project/bad_config ---
```

## Output Format

```
CONFIG                           STATUS  IP              COUNTRY  CITY     ASN     ORG                LATENCY
server-01.conf                   OK      203.0.113.20    Germany  Frankfurt AS12345 Example GmbH    42 ms
server-02.conf                   BAD     -               -        -        -       -                 timeout
server-03.conf                   OK      198.51.100.8    Finland  Helsinki AS54321 Example Oy      58 ms

Checked: 3 | Working: 2 | Failed: 1

Moved to bad_config:
  server-02.conf

Tip: restore a config by moving it back to ./config
```

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | All configs are working |
| `1` | One or more configs were rejected and moved |
| `2` | Checker error (missing directory, Docker issue, etc.) |

## What It Checks

For each config file:

1. **Tunnel startup** — `awg-quick up wg0`
2. **Connectivity** — HTTPS through the tunnel (dual endpoints)
3. **Public IP** — via GeoIP API through the active `wg0` interface
4. **GeoIP info** — country, city, ASN, provider
5. **Latency** — 3 probes, median value

A config passes only if all steps succeed.

## Non-working Configs

Failed configs are always moved to `bad_config/`:

1. File is copied to `bad_config/`
2. Original is deleted from the source directory
3. If name exists in `bad_config/`, timestamp is appended

This is non-reversible by the checker.
To restore, move the file back manually.

## Differences from Automatic Failover

| Aspect | Automatic (container) | Manual (checker) |
|---|---|---|
| Runs inside container | Yes | Isolated temp container |
| Port exposure | SOCKS5/HTTP on host | None (internal only) |
| Checks current tunnel | Yes (continuous) | Per-file (sequential) |
| Moves bad configs | Yes | Yes (always) |
| Output | Logs only | Formatted table |
| Requires running container | Yes | No |

## Running in Cron

```bash
# Check configs daily at 3 AM
0 3 * * * /path/to/proxy-checker /path/to/config --bad-dir /path/to/bad_config >> /var/log/proxy-checker.log 2>&1
```

## Environment Variables

The checker respects these from `.env` or the host environment:

| Variable | Effect |
|---|---|
| `HEALTH_URLS` | Endpoints for health check |
| `FAILOVER_TIMEOUT` | HTTPS probe timeout |

## Troubleshooting

**"Directory not found"**
Check the path. The directory must exist and contain `.conf` files.

**"No .conf files found"**
The directory exists but is empty. Add AmneziaWG config files.

**"Building image" on every run**
The image was not found. Run `docker compose build` first, or let the wrapper build it automatically.

**Container fails to start**
The checker needs `NET_ADMIN` capability. The wrapper passes `--cap-add NET_ADMIN` automatically.

**Working configs are reported BAD**
Stop the failover container first (`docker compose down`). Running both at once
makes them fight over the same WireGuard keys and endpoint.

**GeoIP shows N/A**
The external `ipwho.is` lookup failed. The `OK`/`BAD` verdict and the public IP
are still valid; only country/city/ASN are missing.

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for more.
