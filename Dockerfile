FROM ghcr.io/mainfrezzer/amnezia-bridge:latest

RUN apk add --no-cache curl jq

COPY scripts /scripts
COPY scripts/check-tunnel.sh /check-tunnel.sh
COPY scripts/failover-manager.sh /failover-manager.sh
COPY scripts/entrypoint.sh /entrypoint.sh

RUN chmod +x /scripts/*.sh /check-tunnel.sh /failover-manager.sh /entrypoint.sh \
    && mkdir -p /etc/amnezia/amneziawg

ENTRYPOINT ["/entrypoint.sh"]
