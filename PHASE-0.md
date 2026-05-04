# Phase 0 — FrankenPHP + Caddy + Souin spike

Running notes for the tech-lead spike before any production work begins on `fp-runtime`.
Outcome of this phase: a working local container, a decision memo on Souin integration
strategy, and a list of risks the platform team must accept (or mitigate) before Phase 1.

## Goals

1. Stand up a hello-world FrankenPHP container locally.
2. Compile in Souin via xcaddy. Confirm the binary boots and Caddy reports the cache module loaded.
3. Verify Souin tag-based invalidation works against the chosen backend.
4. Confirm whether a maintained Souin/WordPress integration plugin already exists, or whether we own that code.

## Findings (research)

### Souin / cache-handler

- **`caddyserver/cache-handler`** is the production-stable wrapper around Souin.
  The Souin repo itself is the development version; cache-handler picks up
  features once they stabilise. **We use cache-handler**, not
  `darkweak/souin/plugins/caddy` directly.
- **Latest cache-handler:** v0.16.0 (July 2025). Pin in Phase 1.
- **Module path:** `github.com/caddyserver/cache-handler`.
- **Storage backends:** Badger, Nuts, Otter, Olric, Etcd, Redis, Simplefs.
  **No memcached.** Redis is the right choice for distributed HTTP cache.
- **Invalidation:** `PURGE / Surrogate-Key: key1, key2` — clean, RESTful,
  emitted by the WP mu-plugin on `save_post` / `clean_post_cache` / etc.

### WordPress integration

- **No upstream Souin WordPress plugin exists.** Confirmed against Souin docs and GitHub.
- The `Proxy Cache Purge` (varnish-http-purge) plugin emits Cache-Tags and can do
  Surrogate-Key purges — but it's Varnish-flavoured and would need adaptation. Not
  a clean fit.
- **Decision: write our own `SouinInvalidator` mu-plugin component** in
  [`fp-mu-plugin`](https://github.com/EightOEight/fp-mu-plugin). It's small —
  hooks `save_post` / `deleted_post` / `clean_post_cache` / `switch_theme` /
  `permalink_structure_changed`, emits `Surrogate-Key` headers on responses,
  sends `PURGE / Surrogate-Key: ...` to the Souin admin API on writes.

### FrankenPHP + Souin known issues

- [`php/frankenphp#1062`](https://github.com/php/frankenphp/issues/1062) — open
  as of Oct 2024. Reported: PURGE returns 204 but doesn't clear cache;
  `responseWriter is not a flusher` errors with Souin's API endpoints; storage
  backend behaviour differs (Otter vs Badger).
- [`php/frankenphp#982`](https://github.com/php/frankenphp/issues/982) — closed
  Dec 2024 (build instructions question, not a behavioural bug).
- **Risk:** the FrankenPHP+Souin combo is not battle-tested. We must validate
  PURGE-by-Surrogate-Key end-to-end ourselves in this spike. If the reported
  bugs persist with cache-handler v0.16.0 and current FrankenPHP, fallback
  options are:
  1. Run Caddy+Souin as a sidecar in front of FrankenPHP (defeats the
     single-process simplification but preserves cache).
  2. Drop origin-side Souin and rely on edge CDN (Cloudflare/CloudFront) only.

### Cache backend implications

- Souin needs **Redis**. Existing EightOEight infrastructure runs **memcached**
  for WP `object-cache.php` (the wp-mu-plugin's drop-in).
- These are two separate caches: WP object cache (DB queries, transients,
  in-process) vs Souin HTTP cache (full response bodies, cross-replica).
- **Two-cache option (recommended for Phase 1):** keep memcached for WP object
  cache, add Redis for Souin. The Helm chart in `fp-charts` will support both.
- **Single-cache option:** migrate WP object cache to Redis. Smaller infra
  surface but a side migration we don't need to bundle. Leave it as a future
  values-toggle for end users.

## Spike scope (this repo, `spike/phase-0` branch)

Files added in this branch:

- `Dockerfile` — multi-stage. Builder image based on `dunglas/frankenphp:builder-php8.3`,
  xcaddy build adds `caddyserver/cache-handler` + `dunglas/caddy-cbrotli`. Runtime
  image based on `dunglas/frankenphp:php8.3` + WP-relevant PHP extensions + wp-cli.
- `Caddyfile` — global `cache` block with Redis backend + per-server `cache` directive.
  WP-style `try_files`. `.php` whitelist (only WP entry points may execute PHP).
  `/healthz` endpoint. Metrics on `:9145`.
- `php.ini` — opcache + memory tuning suitable for WordPress under FrankenPHP worker mode.
- `web/index.php` — tiny test app emitting `Surrogate-Key` based on URL path
  (`/post/N` → `post-N posts`, `/` → `home posts`). Renders a microsecond timestamp
  so cache hits are visually obvious (frozen value).
- `docker-compose.yml` — runtime + Redis sidecar.
- `tests/cache-spike.sh` — bash assertions:
  1. `/healthz` returns 200.
  2. `.php` whitelist returns 404 for arbitrary `.php` paths.
  3. First `GET /post/1` is MISS, second is HIT.
  4. `PURGE / Surrogate-Key: post-1` invalidates only that entry.
  5. `/post/2` caches independently of `/post/1`.

## How to run

```bash
docker compose up --build
# in another terminal:
./tests/cache-spike.sh
```

## Open questions for the user

1. **Single-cache vs two-cache** for Phase 1 (memcached for WP object cache + Redis
   for Souin HTTP cache, vs Redis for both). Defaulting to two-cache; flag if a
   single-cache simplification is preferred.
2. **Cache-handler version pinning** — pin to v0.16.0 in Phase 1, or track main?
   Recommend v0.16.0 pin.
3. **Fallback if FrankenPHP+Souin is buggy** — document the sidecar approach as a
   pre-mitigation, or only address it if the spike's PURGE test fails?

## Decision memo

To be filled in after the spike runs end-to-end. Sections:
- Did the build succeed?
- Did PURGE-by-Surrogate-Key work?
- Did issue #1062's symptoms reproduce?
- Recommended Phase 1 architecture: in-process Souin vs sidecar vs edge-CDN-only.
