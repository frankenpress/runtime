# Phase 0 — FrankenPHP + Caddy + Souin spike

Running notes for the tech-lead spike before any production work begins on `runtime`.
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
  [`mu-plugin`](https://github.com/frankenpress/mu-plugin). It's small —
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
  cache, add Redis for Souin. The Helm chart in `charts` will support both.
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

## Spike run log

### Iteration 1 (commit `d5e0397`)

- **Build:** ✅ succeeded. `dunglas/frankenphp:builder-php8.3` + xcaddy build with
  `caddyserver/cache-handler` + `dunglas/caddy-cbrotli`. ~2.5 min on Apple Silicon.
  Final image 709 MB (over the 250 MB Phase 1 target — slim in Phase 1 by
  pruning dev tooling and ext deps).
- **Boot:** ✅ FrankenPHP 8.3.30 starts cleanly. Caddy + Souin module loaded.
- **`/healthz`:** ✅ 200.
- **`.php` whitelist:** ❌ initial `respond @bad_php 404` at top level lost the
  ordering race against `php_server` (which fell through to `/index.php` on
  unknown `.php` paths and returned 200). **Fix:** wrap whitelist + cache + php
  in mutually-exclusive `handle` blocks so the first match wins regardless of
  Caddy's directive auto-ordering. Applied — passing in iteration 2.
- **Cache MISS/HIT:** ✅ `Cache-Status: Souin; fwd=uri-miss; stored` on first
  GET, `hit` on second. Cache-key generation works.
- **PURGE:** ❌ returned `Cache-Status: Souin; fwd=bypass; detail=UNSUPPORTED-METHOD`.
  Two real bugs caught here:

  **Bug A — Souin storage silent fallback.** Caddy log:
  ```
  Error during Redis init, did you include the Redis storage
  (--with github.com/darkweak/storages/redis/caddy or
  github.com/darkweak/storages/go-redis/caddy)?
  unknown module: storages.cache.redis
  ```
  Souin **kept running with the in-memory default storage** even though the
  Caddyfile asked for Redis. Cache appeared functional locally but would not
  survive a pod restart and would not share state across replicas — exactly
  the kind of bug that would silently break in production. Fix: explicit
  `--with github.com/darkweak/storages/go-redis/caddy` in the xcaddy build.

  **Bug B — Souin API not registered by default.** `/souin-api/souin` was
  routing through to PHP (rendered as `Page: /souin-api/souin` by the test
  app), meaning cache-handler v0.16.0 does **not** auto-register the API
  endpoint when only `cache { ... }` is declared. Fix: explicit
  `api { souin }` block inside the global `cache` block.

- **Caddyfile deprecation:** `servers { metrics }` is deprecated; moved to
  top-level `metrics` global option.

### Iteration 2 (xcaddy go-redis storage + api basepaths)

- Added `--with github.com/darkweak/storages/go-redis/caddy` to the xcaddy build.
- Caddyfile: explicit `api { basepath /souin-api souin { basepath / } }`.
- Top-level `metrics` (deprecation fix).
- Catch-all `handle { cache; ... }` plus a dedicated `handle /souin-api/* { cache; respond 503 }` to surface API-registration failures loudly.

**Result:** Redis confirmed as the actual storage backend (Cache-Status now reports `detail=REDIS`, no more "default storage" warning). But:
- `/souin-api/...` returned 503 (the fallback) — cache directive let the request through, did NOT register the admin API on the public port.
- Caddy admin-endpoint dump (`localhost:2019/config/apps/cache/api`) showed `souin.enable: true` but the actual handler routes weren't being mounted on the public listener.

**Why:** the cache-handler `admin.go` source registers Souin's admin via `caddy.AdminRoute`, **on the localhost:2019 admin endpoint, not on the public HTTP server**. So `api { ... }` in cache-handler v0.16.0 controls a *Caddy admin endpoint*, not a public-facing API. From inside the runtime container, hitting `localhost:2019/api.souin/` and `localhost:2019/souin/` both returned `{"error":"resource not found: ..."}` — the souin admin module receives the request but its `InternalEndpointHandlers` map appears empty, so nothing matches.

### Iteration 3 (allowed_http_verbs + behavioural test of every documented invalidation pattern)

Added `allowed_http_verbs GET HEAD POST PUT PATCH DELETE PURGE` to the global cache block — the loaded config previously showed `"allowed_http_verbs": []`, which Souin treats as GET-only.

After rebuild + Redis flush, tested every documented invalidation pattern:

| Pattern | Documented behavior | Actual behavior in cache-handler v0.16.0 |
|---|---|---|
| `PURGE /post/1` | Drop cached GET /post/1 | **Caches the PURGE response itself** (key `PURGE-http-...-/post/1` appears in Redis). GET /post/1 still HIT after. |
| `POST /post/1` (CRUD pattern from Souin docs) | Drop cached GET /post/1 | Same — caches POST response, GET stays HIT. |
| `DELETE /post/1` (CRUD pattern) | Drop cached GET /post/1 | Same — UNSUPPORTED-METHOD until allowed, then caches the response. |
| `PURGE /` with `Surrogate-Key: post-1` header (Souin docs example) | Drop entries tagged `post-1` | UNSUPPORTED-METHOD until allowed; caches PURGE response after. |
| `PURGE /api.souin/souin/post-1` on admin port :2019 | Surrogate-key invalidation | 404 from souin admin handler (handlers map empty). |
| `DEL` directly on Redis keys | not documented | **Works perfectly.** Cache MISS on next GET, regenerates fresh. |

**Key Redis structure observed** (after a few cached requests):
```
GET-http-localhost:8080-/post/1        # the cached response body
IDX_GET-http-localhost:8080-/post/1    # index entry pointing at the body
SURROGATE_/post/1                      # auto-generated url-keyed surrogate index
SURROGATE_posts post-1                 # surrogate key from PHP's Surrogate-Key header
```

This is the actionable invalidation primitive. The mu-plugin's `SouinInvalidator` (Phase 2 deliverable in `mu-plugin`) will:
1. Connect to Redis directly (the runtime image already includes `redis` PHP ext).
2. On `save_post` / `clean_post_cache` / `permalink_structure_changed` / etc., compute the cache key (`GET-{scheme}-{host}-{path}`) for the affected URLs.
3. `DEL` the body key, the IDX_ key, and any matching SURROGATE_ keys.
4. For tag-based bulk invalidation, read `SURROGATE_<tag>` (a Redis SET) to get the list of cached URL keys, then pipeline-DEL them all.

This is sub-millisecond per invalidation. Far more reliable than the broken HTTP APIs.

## Final decision memo (Phase 0 → Phase 1 hand-off)

**1. Architecture confirmed:** FrankenPHP + Caddy + cache-handler v0.16.0 + go-redis storage. Build is clean, boot is clean, caching works, Redis backend is confirmed (no silent fallback).

**2. Souin HTTP invalidation APIs are not viable in cache-handler v0.16.0.** PURGE, POST/PUT/PATCH/DELETE-CRUD, and the `/api.souin/...` admin endpoint all fail in different ways. The `/souin-api/...` public-port API I assumed exists is not what cache-handler implements — its `api { ... }` block controls a Caddy admin-port handler that's also broken (handler map empty).

**3. Invalidation strategy for Phase 1: direct Redis DEL from the mu-plugin.** Documented Redis key shape is stable enough to depend on. Cleaner than an HTTP API anyway: no parser, no auth, sub-ms operations.

**4. Issue #1062's specific symptoms did not reproduce.** No `responseWriter is not a flusher` errors. PURGE returns 200 (not the 204 the issue reports). The bugs we hit were different — config-related and library-API-misalignment.

**5. Image size:** 709 MB. Phase 1 must slim. Targets: drop dev tooling (php-config, build deps if any leak through), use `php:cli` slim variants if FrankenPHP supports them, prune apt cache aggressively, consider distroless final stage.

**6. Caddyfile structure that works:**
```caddy
{
    auto_https off
    metrics
    cache {
        allowed_http_verbs GET HEAD     # NOT POST/PUT/etc. — those just cache the response.
        api { basepath /souin-api souin { basepath / } }   # cosmetic; doesn't actually mount.
        ttl 5m
        stale 1h
        mode bypass
        redis { url {$REDIS_URL:redis:6379} }
        cdn { strategy hard }
        default_cache_control "public, s-maxage=300"
    }
}
:8080 {
    root * /app/web
    encode zstd br gzip
    @healthz path /healthz
    @bad_php { path *.php; not path /index.php /wp-login.php /wp-cron.php /wp-admin/*.php /wp/index.php /wp/wp-login.php /wp/wp-cron.php /wp/wp-admin/*.php }
    handle @healthz { respond "ok" 200 }
    handle @bad_php { respond 404 }
    handle { cache; try_files {path} {path}/ /index.php?{query}; php_server }
}
:9145 { metrics /metrics }
```

**7. Operational guardrails Phase 1 must inherit:**
- **Fail-fast on storage init error.** Souin's silent fallback to in-memory is the dangerous failure mode; the cache-spike script asserts `detail=REDIS` is in the Cache-Status header, which catches the regression.
- **Pin cache-handler + storages versions.** The `darkweak/storages/*` repos move fast; track specific commits.
- **Don't bother shipping the api block** until cache-handler fixes admin-route registration (or maintain a fork). Direct-Redis DEL doesn't need it.

**8. Open architecture decision the user still needs to make** (was D-1 in the project plan):
- One cache (Redis for both Souin HTTP cache and WP object cache via `predis`/`redis-cache`) or two (Redis for Souin, memcached drop-in for WP object cache).
- Spike doesn't change the question; it just confirms Redis is mandatory regardless.
