# syntax=docker/dockerfile:1.7

# FrankenPress runtime — Phase 0 spike
# FrankenPHP + Caddy with caddyserver/cache-handler (Souin) compiled in.

ARG PHP_VERSION=8.3

# ---------- Builder ----------
FROM dunglas/frankenphp:builder-php${PHP_VERSION} AS builder

COPY --from=caddy:builder /usr/bin/xcaddy /usr/bin/xcaddy

# CGO must be enabled because FrankenPHP embeds libphp.
# XCADDY_SETCAP grants the resulting binary CAP_NET_BIND_SERVICE so it can bind :80/:443
# without running as root.
RUN CGO_ENABLED=1 \
    XCADDY_SETCAP=1 \
    XCADDY_GO_BUILD_FLAGS="-ldflags='-w -s' -tags=nobadger,nomysql,nopgx" \
    CGO_CFLAGS=$(php-config --includes) \
    CGO_LDFLAGS="$(php-config --ldflags) $(php-config --libs)" \
    xcaddy build \
        --output /usr/local/bin/frankenphp \
        --with github.com/dunglas/frankenphp=./ \
        --with github.com/dunglas/frankenphp/caddy=./caddy/ \
        --with github.com/dunglas/caddy-cbrotli \
        --with github.com/caddyserver/cache-handler \
        --with github.com/darkweak/storages/go-redis/caddy

# ---------- Runtime ----------
FROM dunglas/frankenphp:php${PHP_VERSION} AS runtime

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

# wp-cli for cron + admin tasks
RUN curl -fsSL -o /usr/local/bin/wp \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp

COPY Caddyfile /etc/caddy/Caddyfile
COPY php.ini /usr/local/etc/php/conf.d/fp-runtime.ini
COPY web /app/web

WORKDIR /app

EXPOSE 8080 9145

# FrankenPHP runs the bundled Caddyfile by default.
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
