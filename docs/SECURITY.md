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
- The default `PROXY_BIND_ADDRESS=127.0.0.1` binds only to localhost
- For LAN access, bind to a specific trusted host interface and restrict clients with a forwarding firewall policy
- Only expose ports on trusted networks

The active upstream Privoxy configuration inspected in the pinned image only
sets its listener; it has no explicit forwarding, filtering, or CONNECT-port
allowlist directives. A synthetic integration test confirmed that HTTP works
and HTTPS CONNECT to a local nonstandard port (`18443`) is accepted. This
overlay preserves that upstream behavior; it does not newly enable it. Keep the
unauthenticated proxy reachable only from trusted clients. A CONNECT-port
restriction would be a separate proxy-behavior change.

## Bind Address Risk

The default binding is `127.0.0.1`. Setting `PROXY_BIND_ADDRESS=0.0.0.0` exposes proxies to **all network interfaces**. The proxies have no authentication; anyone who can reach them can route traffic through your VPN.

**Recommendation:** Keep the default for local applications:
```dotenv
PROXY_BIND_ADDRESS=127.0.0.1
```

### Docker firewall note

Published Docker ports are forwarded through Docker-managed packet-filter rules. With Docker's iptables backend, ordinary UFW rules and host `INPUT` rules may not filter this forwarded traffic as expected. Apply restrictions in `DOCKER-USER` (accounting for Docker DNAT and the original published destination), or bind the publication to a specific trusted host interface. With Docker's nftables backend, use the corresponding forwarding policy; do not assume the `DOCKER-USER` chain exists. Test the effective rule path on the actual host and Docker backend. A bind address is not authentication or a per-client ACL.

## Fail-Closed Design

The container runs an outbound kill switch (`scripts/killswitch.sh`, chain `AWG_KILLSWITCH` in `OUTPUT`).
It is armed at container start, before any proxy or tunnel process runs, and it stays in place
whether or not `wg0` exists. Only these may leave the container:

- loopback;
- the `wg0` interface;
- the tunnel's own UDP socket, matched by its fwmark (the encrypted tunnel traffic to the endpoint);
- explicitly configured destination CIDRs from `LAN_NETWORK` / `LAN_NETWORK6`;
- TCP replies for established connections accepted on the proxy listener ports;
- DNS on `wg0`; and
- DNS to the configured numeric nameservers only for endpoint-resolver UID `65532` during a short, bounded endpoint-lookup window.

All other UDP/TCP port-53 traffic is rejected before loopback or LAN exceptions. The
proxy processes do not share UID `65532`; therefore a LAN allow does not create a
pre-tunnel DNS bypass. DNS-over-TCP is subject to the same policy. Endpoint
hostnames are resolved before `awg-quick up`; the temporary DNS rule is closed
before AWG starts, and failed resolution leaves the source config unchanged.

Compose intentionally uses `network_mode: bridge` with numeric
`DNS_PRIMARY`/`DNS_SECONDARY` entries. This keeps those server IPs in
`/etc/resolv.conf`; user-defined Docker networks substitute the UID-blind
embedded resolver `127.0.0.11` and are unsupported for this service. The current
Compose project has no service-name dependency. Resolver DNS is sent directly to
the configured server only during endpoint staging; normal proxy DNS must leave
through `wg0`.

Private, link-local and multicast destinations are rejected unless an exact
destination CIDR is explicitly allowed. This includes the common cloud metadata
address range `169.254.0.0/16`. Everything else is rejected unless it uses the
tunnel or the tunnel's marked UDP socket. If `wg0` is missing or down, traffic
does not fall back to the default route on `eth0`.
Each rule update is one `iptables-restore` transaction, so there is no moment with an open firewall.
The proxies keep listening, but their outbound connections fail while no tunnel is up.

If the kill switch cannot be armed or finalized, the failover manager does not start the tunnel.

Split tunneling is not supported; LAN bypass is the only non-tunnel route for
non-DNS traffic. DNS remains tunnel-only except for the dedicated endpoint
resolver window described above.

Verification: `sudo sh tests/killswitch-test.sh` (network namespace, real iptables) and
`sh tests/failover-manager-test.sh`.

## GeoIP Endpoint Privacy

The proxy checker uses external APIs to determine the public IP:
- `https://ipwho.is/` (primary)
- `https://api.ipify.org` (fallback)

These checker requests reveal your VPN exit IP to a third party. The automatic
failover health check instead requests only the configured HTTPS health URLs
(Google Connectivity Check and Cloudflare); it does not call the GeoIP APIs.

## Container Capabilities

The container requires `NET_ADMIN` for:
- Creating and managing the WireGuard tunnel
- Setting up routing tables
- Configuring firewall rules

This is a standard requirement for VPN containers but grants significant network control.
Do not run this container alongside untrusted workloads.

## Config Quarantine

After repeated committed failures, a config is moved to `bad_config/`.
The container copies it there and removes the source file; an operator can
restore it after review, but automatic restoration is not performed.

Rejected configs still contain valid cryptographic material.
If the keys have been compromised, delete the file from `bad_config/` and revoke the keys on the VPN server.

## Docker Socket

This project does **not** require or use the Docker socket.
The proxy checker runs its own isolated container without host Docker access.

## Updates

The base image is pinned by its verified OCI index digest. Before changing that
pin, review upstream changes and rerun the isolated checks:
```bash
docker build --no-cache -t amnezia-bridge-failover:local .
IMAGE=amnezia-bridge-failover:local sh tests/image-smoke-test.sh
```

The pin does not pin Alpine package repositories or make builds bit-for-bit
reproducible. The upstream image has no declared license; pinning does not
resolve that licensing gap. Check the upstream repository for changes to scripts
or proxy configuration before accepting a digest update.

## Upgrade and configuration migration

Before an upgrade, back up Compose, `.env`, `config/`, `bad_config/` and its
strike state. Existing `.env` overrides remain effective. Review broad
`LAN_NETWORK*` entries and narrow them manually: DNS is rejected before LAN
exceptions, but other explicitly allowed destinations still bypass the tunnel.
Review quarantined configs before restoring them; do not automatically put every
file back into `config/`. Proxy authentication and a least-privilege/read-only
container mode are not provided by this release.

## DNS leak incident check (disposable container only)

Run this only in an isolated test container or an explicitly approved
maintenance window. Stop its tunnel and verify synthetic requests through both
SOCKS5 remote DNS and HTTP fail closed; capture DNS on the direct container
interface while issuing synthetic requests, then restore the service and
confirm requests use the tunnel. Include TCP, UDP and IPv6 where enabled. One
failed `curl` request alone does not establish that all DNS or traffic paths are
safe. Never run this procedure against production credentials without an
approved outage window.
