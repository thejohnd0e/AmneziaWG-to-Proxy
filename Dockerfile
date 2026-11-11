# Stage 1: Build amneziawg-go from the pinned 3.1 commit.
# The amnezia-bridge base image ships amneziawg-tools 3.1.20260812 but an
# older amneziawg-go (May 2025) that does not understand 3.1 keys
# (HeaderProtectionKey, RandomTrailers, ...). Only the engine needs replacing.
FROM golang:1.25-alpine AS builder
RUN apk add --no-cache git
WORKDIR /tmp
RUN git clone -q https://github.com/amnezia-vpn/amneziawg-go awg-go \
 && cd awg-go \
 && git checkout -q b5928efb6ca19f0153958460c3d141f04abc5c2e
RUN cd /tmp/awg-go && \
    GOFLAGS=-p=1 GOGC=50 go build -trimpath -ldflags="-s -w" -o /amneziawg-go .

# Stage 2: overlay onto the reviewed amnezia-bridge base image.
FROM ghcr.io/mainfrezzer/amnezia-bridge@sha256:fcfa9ae5f361e257e3451a37730c0886b7c1c2f9664b5dd7021c85201c90dc31

# Replace the legacy amneziawg-go with the 3.1 build.
COPY --from=builder /amneziawg-go /usr/bin/amneziawg-go
RUN chmod 755 /usr/bin/amneziawg-go

# Overlay packages intentionally use current Alpine repositories; the base digest does not freeze package versions.
# hadolint ignore=DL3018
RUN apk add --no-cache curl jq bind-tools su-exec \
    && adduser -D -H -u 65532 -s /sbin/nologin endpoint-resolver

COPY scripts/ /scripts/

# Strip CR in case the build context came from a CRLF checkout or a ZIP download.
# The upstream /healthcheck.sh (a ping through wg0) is replaced by ours, which
# probes through both proxies.
RUN sed -i 's/\r$//' /scripts/*.sh \
    && chmod +x /scripts/*.sh \
    && ln -s /scripts/entrypoint.sh /entrypoint.sh \
    && ln -s /scripts/failover-manager.sh /failover-manager.sh \
    && ln -s /scripts/killswitch.sh /killswitch.sh \
    && ln -s /scripts/check-tunnel.sh /check-tunnel.sh \
    && ln -s /scripts/ensure-tun.sh /ensure-tun.sh \
    && ln -s /scripts/proxy-routes.sh /proxy-routes.sh \
    && ln -s /scripts/resolve-endpoint.sh /resolve-endpoint.sh \
    && ln -sf /scripts/healthcheck.sh /healthcheck.sh \
    && mkdir -p /etc/amnezia/amneziawg

HEALTHCHECK --interval=30s --timeout=20s --start-period=60s --retries=3 CMD ["/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
