# fp-runtime

**FrankenPress runtime image** — the base container image for the FrankenPress
stack.

FrankenPress is an opinionated, minimal way to run WordPress at scale on
Kubernetes: **Caddy + FrankenPHP** for the web server and PHP runtime, **Souin**
(via [`caddyserver/cache-handler`](https://github.com/caddyserver/cache-handler))
for HTTP page cache, and [`humanmade/s3-uploads`](https://github.com/humanmade/S3-Uploads)
for media offload to S3-compatible buckets. Sites are deployed via the
[`fp-charts`](https://github.com/EightOEight/fp-charts) Helm chart.

This repo publishes `ghcr.io/eightoeight/fp-runtime:php<X.Y>` — the base image
that [`fp-site-template`](https://github.com/EightOEight/fp-site-template)
extends.

## Status

🚧 Under construction. Phase 1 in progress.
- **Phase 0** ([PR #1](https://github.com/EightOEight/fp-runtime/pull/1)) —
  tech-lead spike validating FrankenPHP + Caddy + Souin. See [`PHASE-0.md`](./PHASE-0.md).
- **Phase 1** (this branch) — version pinning, env-driven config,
  fp-mu-plugin baking mechanism, CI workflow.

## What's in the image

| Component | Version | Notes |
|---|---|---|
| FrankenPHP | `1.12.2` | Caddy + PHP 8.3 runtime, statically linked |
| caddyserver/cache-handler | `v0.16.0` | Souin HTTP cache, compiled into the binary |
| darkweak/storages/go-redis/caddy | `v0.0.19` | Redis storage backend for Souin |
| dunglas/caddy-cbrotli | `v1.0.1` | Brotli encoding |
| WP-CLI | `2.12.0` | Cron + admin tasks |
| Composer | bundled | Composer 2.x from FrankenPHP base |
| PHP extensions | `gd intl exif zip opcache mysqli pdo_mysql memcached redis` | WP-friendly set |
| fp-mu-plugin | optional | Bake at build time via `FP_MU_PLUGIN_VERSION` (defaults to skip) |

## Consumer pattern

Downstream WordPress site images extend this base:

```dockerfile
# In your-site/Dockerfile
FROM ghcr.io/eightoeight/fp-runtime:php8.3 AS base

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
responsibility — see [`fp-site-template`](https://github.com/EightOEight/fp-site-template).

## Build args

Override at build time with `--build-arg`:

| Arg | Default | Purpose |
|---|---|---|
| `PHP_VERSION` | `8.3` | PHP series. Must match a `dunglas/frankenphp:*-php<X.Y>` tag |
| `FRANKENPHP_VERSION` | `1.12.2` | Pinned FrankenPHP base tag |
| `CACHE_HANDLER_VERSION` | `v0.16.0` | Souin cache-handler module version |
| `STORAGES_GO_REDIS_VERSION` | `v0.0.19` | Souin Redis storage module version |
| `CADDY_CBROTLI_VERSION` | `v1.0.1` | Brotli encoding module version |
| `WP_CLI_VERSION` | `2.12.0` | WP-CLI release |
| `FP_MU_PLUGIN_VERSION` | (empty) | If set, fetches the corresponding fp-mu-plugin tag and installs to `/app/web/app/mu-plugins/fp/`. Empty = skip |

## Page cache invalidation

Souin caches GET responses in Redis. Invalidation is performed by the
[`fp-mu-plugin`](https://github.com/EightOEight/fp-mu-plugin)'s
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
make build         # build fp-runtime:dev
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
| [`fp-runtime`](https://github.com/EightOEight/fp-runtime) (this repo) | Base container image |
| [`fp-mu-plugin`](https://github.com/EightOEight/fp-mu-plugin) | Slim WordPress must-use plugin (URL fixer, Souin invalidator, metrics, object cache) |
| [`fp-site-template`](https://github.com/EightOEight/fp-site-template) | GitHub template for new sites — Bedrock-layout WordPress with S3 uploads |
| [`fp-charts`](https://github.com/EightOEight/fp-charts) | Helm chart `fp-site` for Kubernetes deployment |
