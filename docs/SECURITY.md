# Security Considerations

## Secrets in Config Files

AmneziaWG `.conf` files contain **private keys** and **pre-shared keys**.
These are cryptographic secrets that grant access to your VPN tunnel.

**Never:**
- Commit `.conf` files to Git
- Include them in Docker images
- Share them in logs, issues, or messages
- Store them in cloud storage without encryption

**Always:**
- Keep them only in local `config/` and `bad_config/` directories
- Use `.gitignore` to exclude them
- Set appropriate file permissions (600)

## Proxy Authentication

The SOCKS5 and HTTP proxies have **no authentication**.
Anyone who can reach the proxy ports can use your VPN tunnel.

**Mitigations:**
- Use `PROXY_BIND_ADDRESS=127.0.0.1` to bind only to localhost
- Use firewall rules to restrict access to the proxy ports
- Only expose ports on trusted networks

## Bind Address Risk

Default binding to `0.0.0.0` exposes proxies to **all network interfaces**.
If your machine is on a shared or public network, this allows anyone to route traffic through your VPN.

**Recommendation:** Change to `127.0.0.1` if only local applications need the proxy:
```dotenv
PROXY_BIND_ADDRESS=127.0.0.1
```

## Fail-Closed Design

The container runs an outbound kill switch (`scripts/killswitch.sh`, chain `AWG_KILLSWITCH` in `OUTPUT`).
It is armed at container start, before any proxy or tunnel process runs, and it stays in place
whether or not `wg0` exists. Only these may leave the container:

- loopback;
- the `wg0` interface;
- the tunnel's own UDP socket, matched by its fwmark (the encrypted tunnel traffic to the endpoint);
- LAN ranges from `LAN_NETWORK` / `LAN_NETWORK6` and the built-in private ranges;
- DNS to the resolvers in `resolv.conf`, only while `awg-quick up` runs (it may need to resolve an `Endpoint` host name).

Everything else is rejected. If `wg0` is missing or down, traffic does not fall back to the default route on `eth0`.
Each rule update is one `iptables-restore` transaction, so there is no moment with an open firewall.
The proxies keep listening, but their outbound connections fail while no tunnel is up.

If the kill switch cannot be armed or finalized, the failover manager does not start the tunnel.

**Do not** use `DISABLE_TUNNEL_MODE` (it has no effect in the current code). Split tunneling
is not supported; LAN bypass is the only exception to the VPN path.

Verification: `sudo sh tests/killswitch-test.sh` (network namespace, real iptables) and
`sh tests/failover-manager-test.sh`.

## GeoIP Endpoint Privacy

The health check and proxy checker use external APIs to determine the public IP:
- `https://ipwho.is/` (primary)
- `https://api.ipify.org` (fallback)

These requests reveal your VPN exit IP to a third party.
This is inherent to any connectivity check and cannot be avoided.

## Container Capabilities

The container requires `NET_ADMIN` for:
- Creating and managing the WireGuard tunnel
- Setting up routing tables
- Configuring firewall rules

This is a standard requirement for VPN containers but grants significant network control.
Do not run this container alongside untrusted workloads.

## Config File Movement

When a config is rejected, it is moved to `bad_config/`.
This is a **non-reversible** operation performed by the container.

Rejected configs still contain valid cryptographic material.
If the keys have been compromised, delete the file from `bad_config/` and revoke the keys on the VPN server.

## Docker Socket

This project does **not** require or use the Docker socket.
The proxy checker runs its own isolated container without host Docker access.

## Updates

Before updating the base image, review upstream changes:
```bash
docker compose build --no-cache
```

Check the upstream repository for any changes to scripts or configuration.
