# Troubleshooting

Common issues and solutions.

## Container won't start

**Symptom:** `docker compose up` fails immediately.

**Check logs:**
```bash
docker compose logs amnezia-proxy
```

**Common causes:**
- No `.conf` files in `config/` — the container waits but reports unhealthy
- Invalid `.conf` syntax — the `awg-quick` command fails
- Missing `NET_ADMIN` capability — Docker rejects the startup

## Tunnel fails to start

**Symptom:** Logs show `awg-quick failed` repeatedly.

**Possible causes:**
- Config file contains invalid WireGuard syntax
- Private key is missing or corrupted
- Endpoint is unreachable from the container
- DNS resolution fails inside the container

**Test manually:**
```bash
docker compose exec amnezia-proxy awg-quick up wg0
```

## All configs rejected

**Symptom:** Container is `unhealthy`, all configs in `bad_config/`.

**Steps:**
1. Check `bad_config/` for moved files
2. Verify the configs are still valid on the original VPN provider
3. Move a working config back to `config/`
4. The failover manager will automatically detect and use it

**Common reasons configs fail:**
- Expired or rotated keys
- Server IP changed
- Server is temporarily down
- Network restrictions on the Docker host

## Proxy ports not responding

**Symptom:** `curl --proxy socks5h://localhost:8200 ...` hangs or refused.

**Check:**
```bash
docker compose ps
docker compose logs amnezia-proxy | grep -i proxy
```

**Possible causes:**
- Tunnel is not yet established (first startup takes time)
- Privoxy failed to start (check `HTTPPORT` setting)
- Port conflict on the host

## Docker permission errors

**Symptom:** `permission denied` or `Operation not permitted`.

**Fix:** Ensure `NET_ADMIN` is in `cap_add`:
```yaml
cap_add:
  - NET_ADMIN
```

## Port conflicts

**Symptom:** `Bind for 0.0.0.0:8200 failed: port is already allocated`.

**Fix:** Change the host ports in `docker-compose.yml` or stop the conflicting service:
```bash
ss -tlnp | grep 8200
```

## awg-quick failures

**Symptom:** `awg-quick: command not found` or similar.

**Cause:** The base image was updated and the binary path changed.
**Fix:** Rebuild with `docker compose build --no-cache`.

## GeoIP shows N/A

**Symptom:** IP address is shown but country/city/ASN show `N/A`.

**Cause:** The `ipwho.is` API is temporarily unavailable.
**Effect:** This does NOT affect tunnel health. The config is still considered working.
**Fix:** None needed — the checker continues with available data.

## Health check hangs

**Symptom:** Container health checks take a long time or hang.

**Cause:** DNS resolution inside the container may be slow after tunnel restart.
**Fix:** The `FAILOVER_TIMEOUT` setting limits each probe. Default is 8 seconds.

## Container uses too much memory

**Symptom:** `docker stats` shows high memory usage.

**Cause:** Multiple `awg-quick` restarts may leave zombie processes.
**Fix:** `docker compose restart` will clean up the container.

## Configs not picked up automatically

**Symptom:** New configs added to `config/` are not detected.

**Cause:** The failover manager scans `config/` periodically (every 30 seconds when idle).
**Fix:** Wait up to 30 seconds, or restart the container:
```bash
docker compose restart amnezia-proxy
```

## Log rotation

**Symptom:** Docker logs grow large.

**Fix:** Configure Docker log rotation in `docker-compose.yml`:
```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```
