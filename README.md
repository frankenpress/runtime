# runtime

**FrankenPress runtime image** — the base container image for the FrankenPress
stack.

**Documentation:** <https://docs.frankenpress.com/components/runtime>

FrankenPress is an opinionated, minimal way to run WordPress at scale on
Kubernetes: **Caddy + FrankenPHP** for the web server and PHP runtime, **Souin**
(via [`caddyserver/cache-handler`](https://github.com/caddyserver/cache-handler))
for HTTP page cache, and [`humanmade/s3-uploads`](https://github.com/humanmade/S3-Uploads)
for media offload to S3-compatible buckets. Sites are deployed via the
[`charts`](https://github.com/frankenpress/charts) Helm chart.

This repo publishes `ghcr.io/frankenpress/runtime:php<X.Y>` — the base image
that [`site-template`](https://github.com/frankenpress/site-template)
extends. CI builds a multi-arch manifest list (`linux/amd64` +
`linux/arm64`) for each supported PHP minor; see
[Published tags](#published-tags) for the tag schema.

## What's in the image

| Component | Version | Notes |
|---|---|---|
| FrankenPHP | `1.12.2` | Caddy + PHP runtime, statically linked. Built per supported PHP minor (8.3, 8.4, 8.5) |
| caddyserver/cache-handler | `v0.16.0` | Souin HTTP cache, compiled into the binary |
| darkweak/storages/go-redis/caddy | `v0.0.19` | Redis storage backend for Souin |
| dunglas/caddy-cbrotli | `v1.0.1` | Brotli encoding |
| WP-CLI | `2.12.0` | Cron + admin tasks |
| Composer | not installed | The runtime image is for serving traffic, not building. Install Composer in your site's build stage (or one-shot via `curl -fsSL https://getcomposer.org/installer \| php`) when you need it |
| PHP extensions | `gd intl exif zip opcache mysqli pdo_mysql memcached redis` | WP-friendly set |
| mu-plugin | optional | Bake at build time via `FP_MU_PLUGIN_VERSION` (defaults to skip) |

## Published tags

CI publishes a multi-arch (`linux/amd64` + `linux/arm64`) manifest list
for each supported PHP minor under the schema below.

| Tag | Cadence | Example |
|---|---|---|
| `:php<X.Y>` | rolling, on push to `main` | `:php8.3`, `:php8.4`, `:php8.5` |
| `:php<X.Y>-<short-sha>` | every non-PR push | `:php8.4-abc1234` |
| `:php<X.Y>-v<W.Z>` | on `v*.*.*` tag push | `:php8.4-v0.2.0` |
| `:v<W.Z>` | on `v*.*.*` tag push, **default PHP only** | `:v0.2.0` |

The unprefixed `:v<W.Z>` channel exists so consumers who don't care
which PHP they're on can pin a release tag without encoding the
default. The default PHP is **8.3**; bumping it is a deliberate
decision tracked in `.aidocs/php-wp-runtime-matrix.md`.

## Consumer pattern

Downstream WordPress site images extend this base:

```dockerfile
# In your-site/Dockerfile
FROM ghcr.io/frankenpress/runtime:php8.3 AS base

# 1. composer install your site code in a builder stage
FROM composer:2 AS deps
COPY composer.* /app/
WORKDIR /app
RUN composer install --no-dev --no-scripts --no-autoloader

# 2. assemble the site image
FROM base
COPY --from=deps /app/vendor /app/vendor
COPY web /app/web
COPY config /app/config
```

The runtime image's webroot is `/app/web` by default. Override `FP_DOCROOT`
if your site uses a different layout.

## Environment variables

All runtime tunables. None are required — the defaults produce a working
config out of the box.

| Var | Default | Purpose |
|---|---|---|
| `REDIS_URL` | `redis:6379` | Address of the Redis used by Souin's HTTP cache |
| `FP_CACHE_TTL` | `5m` | Default cache entry TTL |
| `FP_CACHE_STALE` | `1h` | Stale-while-revalidate window |
| `FP_CACHE_DEFAULT_CONTROL` | `public, s-maxage=300` | Cache-Control fallback when upstream doesn't set one |
| `FP_DOCROOT` | `/app/web` | WordPress webroot |
| `FP_PORT` | `8080` | Public HTTP listen port |
| `FP_METRICS_PORT` | `9145` | Prometheus metrics listen port (separate from public traffic) |

WordPress-side env vars (DB credentials, salts, etc.) are the site's
responsibility — see [`site-template`](https://github.com/frankenpress/site-template).

## Logging

The public server (`FP_PORT`) emits **Caddy access logs as JSON to
stdout** — one line per request, with `request.method`, `request.uri`,
`status`, `duration`, `bytes_read`, `resp_headers`, `client_ip`. The
metrics server (`FP_METRICS_PORT`) is **left unlogged on purpose** —
Prometheus scrapes every ~15s would otherwise dominate the log stream.

PHP and WordPress errors flow to **stderr** via
`error_log = /dev/stderr` in `php.ini`. WordPress sites running with
`WP_ENV=staging` additionally route `WP_DEBUG_LOG` to `php://stderr`
(see [`site-template`](https://github.com/frankenpress/site-template/blob/main/config/environments/staging.php)).

Any cluster-side log shipper (Vector, Grafana Alloy, Datadog Agent,
Fluent Bit) that tails container stdout/stderr picks both streams up
unmodified. End-to-end shipping setup (Vector → Loki / Datadog) is
documented at <https://docs.frankenpress.com/operations/logging>.

## Build args

Override at build time with `--build-arg`:

| Arg | Default | Purpose |
|---|---|---|
| `PHP_VERSION` | `8.3` | PHP series. Must match a `dunglas/frankenphp:*-php<X.Y>` tag. CI builds `8.3`, `8.4`, `8.5` |
| `FRANKENPHP_VERSION` | `1.12.2` | Pinned FrankenPHP base tag |
| `CACHE_HANDLER_VERSION` | `v0.16.0` | Souin cache-handler module version |
| `STORAGES_GO_REDIS_VERSION` | `v0.0.19` | Souin Redis storage module version |
| `CADDY_CBROTLI_VERSION` | `v1.0.1` | Brotli encoding module version |
| `WP_CLI_VERSION` | `2.12.0` | WP-CLI release |
| `FP_MU_PLUGIN_VERSION` | `v0.1.1` | [`mu-plugin`](https://github.com/frankenpress/mu-plugin) release tag to bake at `/app/web/app/mu-plugins/fp/`. Pass an empty string to skip baking |

## Page cache invalidation

Souin caches GET responses in Redis. Invalidation is performed by the
[`mu-plugin`](https://github.com/frankenpress/mu-plugin)'s
`SouinInvalidator` connecting **directly to Redis** and `DEL`ing cache keys.
The Souin HTTP invalidation APIs (PURGE, POST-CRUD, `/api.souin/*` admin) are
broken in cache-handler v0.16.0 — see [`PHASE-0.md`](./PHASE-0.md) for the
investigation.

Redis key shape:

```
GET-<scheme>-<host>-<path>     cached response body
IDX_GET-<scheme>-<host>-<path> index entry pointing at the body
SURROGATE_<tag>                set of cache keys for a given Surrogate-Key tag
```

Bulk tag-based invalidation: read `SURROGATE_<tag>` (a Redis SET), then
pipeline-DEL all members. Sub-millisecond.

## Local development

```bash
make build         # build runtime:dev
make up            # docker compose up -d (runtime + redis)
make test          # run tests/cache-spike.sh
make down          # tear down
make ci            # all of the above in one shot
make size          # report compressed image size
```

Or end-to-end:

```bash
make ci
```

## Companion repos

| Repo | Purpose |
|---|---|
| [`runtime`](https://github.com/frankenpress/runtime) (this repo) | Base container image |
| [`mu-plugin`](https://github.com/frankenpress/mu-plugin) | Slim WordPress must-use plugin (S3 uploads bootstrap, Souin invalidator, Site Health overrides, SMTP mailer) |
| [`site-template`](https://github.com/frankenpress/site-template) | GitHub template for new sites — Bedrock-layout WordPress with S3 uploads |
| [`charts`](https://github.com/frankenpress/charts) | Helm chart `site` for Kubernetes deployment |
