FROM ghcr.io/mainfrezzer/amnezia-bridge@sha256:fcfa9ae5f361e257e3451a37730c0886b7c1c2f9664b5dd7021c85201c90dc31

# Overlay packages intentionally use current Alpine repositories; the base digest does not freeze package versions.
# hadolint ignore=DL3018
RUN apk add --no-cache curl jq bind-tools su-exec \
    && adduser -D -H -u 65532 -s /sbin/nologin endpoint-resolver

COPY scripts/ /scripts/

# Strip CR in case the build context came from a CRLF checkout or a ZIP download.
RUN sed -i 's/\r$//' /scripts/*.sh \
    && chmod +x /scripts/*.sh \
    && ln -s /scripts/entrypoint.sh /entrypoint.sh \
    && ln -s /scripts/failover-manager.sh /failover-manager.sh \
    && ln -s /scripts/killswitch.sh /killswitch.sh \
    && ln -s /scripts/check-tunnel.sh /check-tunnel.sh \
    && ln -s /scripts/ensure-tun.sh /ensure-tun.sh \
    && ln -s /scripts/proxy-routes.sh /proxy-routes.sh \
    && ln -s /scripts/resolve-endpoint.sh /resolve-endpoint.sh \
    && ln -s /scripts/healthcheck.sh /healthcheck.sh \
    && mkdir -p /etc/amnezia/amneziawg

HEALTHCHECK --interval=30s --timeout=20s --start-period=60s --retries=3 CMD ["/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
