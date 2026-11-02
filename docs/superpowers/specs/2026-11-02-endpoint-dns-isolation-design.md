# Endpoint DNS isolation design

## Intent

Resolve hostname-based AmneziaWG endpoints without allowing proxy processes to
use a pre-tunnel DNS exception. Preserve normal proxy DNS while the tunnel is
healthy, and fail closed when an endpoint cannot be resolved.

## Approved approach

Use the configured numeric `DNS_PRIMARY`/`DNS_SECONDARY` servers directly from
the container. Run Compose on Docker's standard `bridge` network so Docker writes
those numeric servers into `/etc/resolv.conf` instead of substituting the
embedded `127.0.0.11` resolver. The existing Compose file has one service and no
service-name dependencies, so losing Compose network service discovery is an
acceptable tradeoff for this project.

Install `bind-tools` (`dig`), an endpoint-resolver account with UID `65532`, and
`su-exec` as the UID-switching tool.
During hostname resolution, the kill switch allows only that UID to query the
numeric resolver addresses listed in `/etc/resolv.conf`, over UDP/TCP port 53.
Put this narrow exception before protected-destination rejects so an explicitly
configured private resolver works without granting the proxy a LAN exception.
Route DNS on `wg0` through the tunnel; reject every other UDP/TCP port-53 packet
before loopback or LAN exceptions. The general loopback rule must not be used as
a DNS fallback. Once resolution finishes, close the exception before `awg-quick up`;
proxy DNS uses the tunnel while it is active and is blocked if the tunnel is
down.

Literal numeric endpoints bypass DNS. Bounded A and AAAA queries return a
validated numeric IPv4/IPv6 address within ten seconds. Stage substitutions
in a temporary copy only; never rewrite source config files. If resolution or
firewall cleanup fails, do not start AWG and do not leave readiness or a
temporary DNS permission behind.

## Approaches considered

1. **Approved: direct configured DNS on standard Docker bridge.** Verified on
   `.173`: `/etc/resolv.conf` contains the numeric `--dns` value; UID-owner
   rules permit UID `65532` and block Privoxy UID `100`. Avoids Docker's
   embedded resolver. Tradeoff: no Compose service-name discovery.
2. Keep a user-defined Compose network and allow `127.0.0.11`. Rejected: live
   testing showed DNS queries succeed through the loopback exception for both
   resolver and proxy UIDs, while owner/port-53 rules see no packets.
3. Configure a DNS sidecar or custom proxy stack. Rejected as unnecessary
   scope and more moving parts.

## Goals and non-goals

- Goal: isolate pre-tunnel endpoint DNS by process UID and resolver destination;
  keep proxy-originated DNS tunneled and unavailable while the tunnel is down.
- Goal: support multiple peers, IPv4 and bracketed IPv6 endpoints, bounded
  resolution, and byte-for-byte preservation of source configs.
- Non-goal: proxy authentication, service discovery between Compose services,
  arbitrary DNS fallback, or deployment to a non-test host.

## Verification boundary

Test both UDP and TCP DNS, UID `65532` versus proxy UID, private configured
resolvers, DNS closure, IPv4/IPv6 answer parsing, timeout and signal cleanup in
real disposable containers and Linux network namespaces. Do not claim leak
freedom from shell mocks alone.
