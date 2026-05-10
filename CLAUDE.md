# CLAUDE.md — runtime

Guidance for Claude Code (and other AI agents) when working in this repo.

## What this repo is

The **base container image** for the FrankenPress stack: a single-process
container with **Caddy + FrankenPHP** (worker-mode-capable) and Souin
(via [`caddyserver/cache-handler`](https://github.com/caddyserver/cache-handler))
compiled into the binary via xcaddy. WP-CLI, Composer, and
[`mu-plugin`](https://github.com/frankenpress/mu-plugin) are baked
in. Sites extend this base via [`site-template`](https://github.com/frankenpress/site-template).

Published image: **`ghcr.io/frankenpress/runtime:php8.3`** + version
tags (`v0.1.0`, `php8.3-v0.1.0`).

Public docs: **<https://docs.frankenpress.com/components/runtime>**

## File layout

- `Dockerfile` — multi-stage. Builder stage runs xcaddy with FrankenPHP + cache-handler + go-redis storage + cbrotli pinned to specific versions. Runtime stage installs PHP extensions, wp-cli, copies the rebuilt binary on top, strips the binary's `cap_net_bind_service` file capability, bakes `mu-plugin`. **All upstream pins live as `ARG`s at the top — bump deliberately.**
- `Caddyfile` — env-driven. Global `cache` block (Souin) + per-server block with `try_files` for WP rewrites, `.php` whitelist (only WP entry points may execute PHP), `/healthz`, metrics on `:9145`. Documents every env var at the top.
- `php.ini` — opcache + memory tuning suitable for WordPress under FrankenPHP worker mode.
- `web/index.php` — tiny test app emitting `Surrogate-Key` headers + a microsecond timestamp. Not the production WordPress entry point — that comes from `site-template`. **Don't delete: `tests/cache-spike.sh` depends on it.**
- `tests/cache-spike.sh` — bash assertions: cache MISS/HIT, Redis backend confirmed, `.php` whitelist 404, healthz 200, **direct Redis DEL invalidates** (the canonical mu-plugin invalidation path).
- `docker-compose.yml` — local dev harness: runtime + Redis sidecar.
- `Makefile` — `build / up / down / test / ci / shell / logs / size / clean` targets.
- `PHASE-0.md` — historical investigation log: why direct Redis DEL beat Souin's HTTP invalidation APIs in cache-handler v0.16.0. Read before changing any cache invalidation logic.
- `.github/workflows/build.yml` — push to GHCR on push-to-main + tags. Cache-spike runs in CI as the integration test.

## Conventions

- **Pin every upstream dep as a Dockerfile `ARG`.** Bump deliberately, not via floating tags. The full pin matrix is in the README's build-args table.
- **Cap_net_bind_service is stripped from the frankenphp binary** (`setcap -r` after the COPY). We bind `FP_PORT=8080` (high port); the cap was unused and made the binary unexecutable under `no_new_privs`. **Don't reintroduce it.**
- **mu-plugin is baked at `/app/web/app/mu-plugins/fp/`** by default. The bake step downloads the tarball for `FP_MU_PLUGIN_VERSION` (defaults to a specific tag, e.g. `v0.1.1`). Pass an empty string to skip baking when the consumer site composer-installs it themselves.
- **Caddyfile env vars are documented at the top of the file.** When adding a new env var, document it there too — it's the single source of truth.

## Don'ts

- **Don't add nginx, php-fpm, or supervisord.** This is a single-process FrankenPHP container by design. The whole point of FrankenPress is one process per pod.
- **Don't add `XCADDY_SETCAP=1` back without also removing the `setcap -r` line.** They're contradictory and produce a binary the kernel refuses to exec under `no_new_privs`.
- **Don't add memcached as a Souin storage backend.** Souin/cache-handler doesn't support it. Redis (or anything RESP-compatible like DragonflyDB) is the only supported option.
- **Don't change the cache key shape (`GET-<scheme>-<host>-<path>`)** without coordinating with `mu-plugin`'s `SouinInvalidator`. The mu-plugin DELs Redis keys directly using this exact prefix; a change here breaks invalidation silently.
- **Don't make breaking changes to `FP_*` env var names** in a patch release. They're a public contract — sites + the Helm chart depend on them.
- **Don't drop `tests/cache-spike.sh` even if you're refactoring.** It's the runtime image's only integration test and CI gates on it.

## Local testing

```bash
make ci             # build + up + cache-spike + down
make build          # just rebuild runtime:dev
make size           # report compressed image size (~221 MB target)
```

## When you bump a public env var or build arg

If you rename or change defaults for any public `FP_*`, build arg, or
Caddyfile knob, update:

1. The Caddyfile header (the one source of truth for env vars)
2. README's env-var / build-arg tables
3. `https://docs.frankenpress.com/components/runtime` (in [`docs`](https://github.com/frankenpress/docs))
4. `https://docs.frankenpress.com/operations/configuration`

## Companion repos

| Repo | Purpose |
|---|---|
| [`runtime`](https://github.com/frankenpress/runtime) (this repo) | Base container image |
| [`mu-plugin`](https://github.com/frankenpress/mu-plugin) | Must-use plugin (S3 bootstrap + Souin invalidator) |
| [`site-template`](https://github.com/frankenpress/site-template) | GitHub template for new sites |
| [`charts`](https://github.com/frankenpress/charts) | Helm chart `site` |
| [`docs`](https://github.com/frankenpress/docs) | Mintlify docs site |
