# fp-runtime

**FrankenPress runtime image** — the base container image for the FrankenPress stack.

FrankenPress is an opinionated, minimal way to run WordPress at scale on Kubernetes:
**Caddy + FrankenPHP** (worker mode) for the web server and PHP runtime, **Souin** (via
[`caddyserver/cache-handler`](https://github.com/caddyserver/cache-handler)) for HTTP
page cache, and [`humanmade/s3-uploads`](https://github.com/humanmade/S3-Uploads) for
media offload to S3-compatible buckets. Sites are deployed via the
[`fp-charts`](https://github.com/EightOEight/fp-charts) Helm chart.

This repo publishes `ghcr.io/eightoeight/fp-runtime:php<X.Y>` — the base image that
[`fp-site-template`](https://github.com/EightOEight/fp-site-template) extends.

## Status

🚧 Under construction. Currently in **Phase 0** — a tech-lead spike validating the
FrankenPHP + Caddy + Souin combination. See [`PHASE-0.md`](./PHASE-0.md) for the
running notes and decision memo.

## Companion repos

| Repo | Purpose |
|---|---|
| [`fp-runtime`](https://github.com/EightOEight/fp-runtime) (this repo) | Base container image |
| [`fp-mu-plugin`](https://github.com/EightOEight/fp-mu-plugin) | Slim WordPress must-use plugin (URL fixer, Souin invalidator, metrics, object cache) |
| [`fp-site-template`](https://github.com/EightOEight/fp-site-template) | GitHub template for new sites — Bedrock-layout WordPress with S3 uploads |
| [`fp-charts`](https://github.com/EightOEight/fp-charts) | Helm chart `fp-site` for Kubernetes deployment |
