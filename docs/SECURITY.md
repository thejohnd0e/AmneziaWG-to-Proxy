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

When all configs fail, the container becomes `unhealthy` and stops serving proxy traffic.
This is intentional: traffic should never flow outside the VPN tunnel.

**Do not** use `DISABLE_TUNNEL_MODE` unless you explicitly want split tunneling,
as this allows some traffic to bypass the VPN.

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
