# Third-Party Dependencies

This project builds on top of several open-source components.

## Upstream Base Image

**Mainfrezzer/amnezia-bridge**
- Repository: https://github.com/Mainfrezzer/amnezia-bridge
- Image: `ghcr.io/mainfrezzer/amnezia-bridge:latest`
- License: **None declared**

The upstream project provides the base AmneziaWG tunnel container with Privoxy and microsocks.
Our project adds a thin overlay on top of this image without modifying its core functionality.

**Important:** Since the upstream project has no declared license, redistribution of the complete layered image may have legal implications. This project's source code is MIT-licensed, but the combined image inherits the upstream's licensing status.

## AmneziaWG

- Repository: https://github.com/amnezia-vpn/amneziawg-go (tunnel implementation)
- Repository: https://github.com/amnezia-vpn/amneziawg-tools (CLI tools)
- License: MIT

AmneziaWG is a fork of WireGuard with additional obfuscation capabilities.
Both `awg` and `awg-quick` are provided by these tools.

## microsocks

- Repository: https://github.com/rofl0r/microsocks
- License: GPL-2.0

Lightweight SOCKS5 server used for the proxy endpoint.

## Privoxy

- Website: https://www.privoxy.org
- License: GPL-2.0

Privacy-enhancing HTTP proxy with CONNECT support for HTTPS tunneling.

## GeoIP Services

Used for public IP detection and geolocation in the proxy checker.

| Service | URL | License | Used For |
|---|---|---|---|
| ipwho.is | https://ipwho.is/ | Free tier, no key | Primary GeoIP lookup |
| Cloudflare | https://www.cloudflare.com/cdn-cgi/trace | Free | Fallback IP check |
| ipify | https://api.ipify.org | Free, no key | Fallback IP lookup |

## Health Check Endpoints

| Service | URL | Purpose |
|---|---|---|
| Google Connectivity Check | https://connectivitycheck.gstatic.com/generate_204 | Tunnel health verification |
| Cloudflare | https://cp.cloudflare.com/generate_204 | Tunnel health verification (fallback) |

These endpoints are used only for connectivity testing and do not send any personal data.

## License Summary

| Component | License | How Used |
|---|---|---|
| Our code + docs | MIT | Overlay scripts, Dockerfile, documentation |
| Upstream base image | None declared | Base layer for Docker image |
| AmneziaWG | MIT | VPN tunnel implementation |
| microsocks | GPL-2.0 | SOCKS5 proxy server |
| Privoxy | GPL-2.0 | HTTP proxy server |

The GPL-2.0 components (microsocks, Privoxy) are used as-is within the upstream image.
Our overlay scripts do not link against or modify these components.
