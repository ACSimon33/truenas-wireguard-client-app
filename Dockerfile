FROM debian:bookworm-slim

ARG BUILD_DATE
ARG VCS_REF

LABEL \
  org.opencontainers.image.title="TrueNAS WireGuard Client App" \
  org.opencontainers.image.description="Generic WireGuard client container intended for TrueNAS SCALE Custom Apps" \
  org.opencontainers.image.licenses="MIT" \
  org.opencontainers.image.created="${BUILD_DATE}" \
  org.opencontainers.image.revision="${VCS_REF}"

RUN \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    dumb-init \
    iproute2 \
    iptables \
    openresolv \
    procps \
    wireguard-tools \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /tmp/*

COPY entrypoint.sh /usr/local/bin/wireguard-client-entrypoint
RUN chmod 0755 /usr/local/bin/wireguard-client-entrypoint

VOLUME ["/config"]

HEALTHCHECK \
  --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wg show "${WG_IF:-wg0}" >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/usr/local/bin/wireguard-client-entrypoint"]
