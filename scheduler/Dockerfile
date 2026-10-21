# syntax=docker/dockerfile:1

FROM docker:28.5.2-cli

# Default keeps a plain `docker build` working. BuildKit overrides this per architecture.
ARG TARGETARCH=amd64
ARG SUPERCRONIC_VERSION=0.2.50
ARG COMPOSE_VERSION=5.6.0

RUN apk add --no-cache ca-certificates curl jq tzdata \
    && case "$TARGETARCH" in \
         amd64) \
           sc_arch=amd64; sc_sum=d2d7c97fbfefc763d5bbcbbb3f8d61f9dd3410ce5d05a737c414994b80b8cdd0; \
           co_arch=x86_64; co_sum=40343e21ca777173e69cff5dbafeb37c6f81f3b0d57d9e597f036e95eb63e76a ;; \
         arm64) \
           sc_arch=arm64; sc_sum=a1c0af9872e8de89a1ce5c1b596e26c42917d5a2cf914d98faee2e28156899e2; \
           co_arch=aarch64; co_sum=733ec76717ceb59052a9609b9dadfb523b2df8eab57a54212872d10a58078ea2 ;; \
         *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /usr/local/bin/supercronic \
         "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-${sc_arch}" \
    && echo "${sc_sum}  /usr/local/bin/supercronic" | sha256sum -c - \
    && chmod 755 /usr/local/bin/supercronic \
    && mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
         "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${co_arch}" \
    && echo "${co_sum}  /usr/local/lib/docker/cli-plugins/docker-compose" | sha256sum -c - \
    && chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose \
    && docker compose version \
    && supercronic -version

COPY crontab /etc/crontab
COPY reset-desktops.sh /usr/local/bin/reset-desktops.sh
COPY entrypoint.sh /usr/local/bin/scheduler-entrypoint.sh
RUN chmod 755 /usr/local/bin/reset-desktops.sh /usr/local/bin/scheduler-entrypoint.sh \
    && supercronic -test /etc/crontab

ENTRYPOINT ["/usr/local/bin/scheduler-entrypoint.sh"]
