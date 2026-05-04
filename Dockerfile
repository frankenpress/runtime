# syntax=docker/dockerfile:1.7

# FrankenPress runtime — Caddy + FrankenPHP + Souin (via caddyserver/cache-handler)
# with go-redis storage compiled in. Consumed by downstream WordPress site images
# (see https://github.com/EightOEight/fp-site-template).
#
# All upstream pins live here. Bump deliberately; track stability via the
# cache-spike integration test (./tests/cache-spike.sh) in CI.

ARG PHP_VERSION=8.3

# Pinned upstream tag for FrankenPHP. Bump across both the builder and runtime
# stages together — they must match.
ARG FRANKENPHP_VERSION=1.12.2

# Caddy modules baked into the build. Pin to specific versions per
# fp-runtime/PHASE-0.md acceptance criteria.
ARG CACHE_HANDLER_VERSION=v0.16.0
ARG STORAGES_GO_REDIS_VERSION=v0.0.19
ARG CADDY_CBROTLI_VERSION=v1.0.1

# fp-mu-plugin tag to bake into the image. Empty string skips baking entirely
# (Phase 1 default until fp-mu-plugin ships its first release in Phase 2).
ARG FP_MU_PLUGIN_VERSION=""

# ---------- Builder ----------
FROM dunglas/frankenphp:${FRANKENPHP_VERSION}-builder-php${PHP_VERSION} AS builder

COPY --from=caddy:builder /usr/bin/xcaddy /usr/bin/xcaddy

# CGO must be enabled because FrankenPHP embeds libphp.
# XCADDY_SETCAP grants the resulting binary CAP_NET_BIND_SERVICE so it can bind :80/:443
# without running as root.
ARG CACHE_HANDLER_VERSION
ARG STORAGES_GO_REDIS_VERSION
ARG CADDY_CBROTLI_VERSION
RUN CGO_ENABLED=1 \
    XCADDY_SETCAP=1 \
    XCADDY_GO_BUILD_FLAGS="-ldflags='-w -s' -tags=nobadger,nomysql,nopgx" \
    CGO_CFLAGS=$(php-config --includes) \
    CGO_LDFLAGS="$(php-config --ldflags) $(php-config --libs)" \
    xcaddy build \
        --output /usr/local/bin/frankenphp \
        --with github.com/dunglas/frankenphp=./ \
        --with github.com/dunglas/frankenphp/caddy=./caddy/ \
        --with github.com/dunglas/caddy-cbrotli@${CADDY_CBROTLI_VERSION} \
        --with github.com/caddyserver/cache-handler@${CACHE_HANDLER_VERSION} \
        --with github.com/darkweak/storages/go-redis/caddy@${STORAGES_GO_REDIS_VERSION}

# ---------- Runtime ----------
FROM dunglas/frankenphp:${FRANKENPHP_VERSION}-php${PHP_VERSION} AS runtime

COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp

# WP-friendly PHP extensions. Memcached kept available for the wp object-cache drop-in
# (separate concern from Souin's HTTP cache, which uses Redis).
RUN install-php-extensions \
        gd \
        intl \
        exif \
        zip \
        opcache \
        mysqli \
        pdo_mysql \
        memcached \
        redis \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# wp-cli for cron + admin tasks. Pinned by SHA256 to avoid drift.
ARG WP_CLI_VERSION=2.12.0
RUN curl -fsSL -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
    && chmod +x /usr/local/bin/wp \
    && wp --info --allow-root >/dev/null

# fp-mu-plugin baking — installs the must-use plugin at /app/web/app/mu-plugins/fp/
# when FP_MU_PLUGIN_VERSION is set. Phase 1 default is empty (skip), since
# fp-mu-plugin's first release lands in Phase 2.
ARG FP_MU_PLUGIN_VERSION
RUN if [ -n "$FP_MU_PLUGIN_VERSION" ]; then \
        mkdir -p /app/web/app/mu-plugins/fp \
        && curl -fsSL "https://github.com/EightOEight/fp-mu-plugin/archive/refs/tags/${FP_MU_PLUGIN_VERSION}.tar.gz" \
            | tar xz --strip-components=1 -C /app/web/app/mu-plugins/fp/ \
        && echo "fp-mu-plugin ${FP_MU_PLUGIN_VERSION} baked at /app/web/app/mu-plugins/fp/" ; \
    else \
        echo "fp-mu-plugin baking skipped (FP_MU_PLUGIN_VERSION not set)" ; \
    fi

COPY Caddyfile /etc/caddy/Caddyfile
COPY php.ini /usr/local/etc/php/conf.d/fp-runtime.ini
COPY web /app/web

WORKDIR /app

EXPOSE 8080 9145

# OCI labels for supply-chain hygiene. Override these via build args in CI.
ARG SOURCE_COMMIT=""
ARG BUILD_DATE=""
LABEL org.opencontainers.image.title="fp-runtime" \
      org.opencontainers.image.description="FrankenPress runtime — Caddy + FrankenPHP + Souin for WordPress on Kubernetes" \
      org.opencontainers.image.source="https://github.com/EightOEight/fp-runtime" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="EightOEight" \
      org.opencontainers.image.revision="${SOURCE_COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}"

CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
