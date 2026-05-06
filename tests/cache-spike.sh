#!/usr/bin/env bash
# Phase 0 cache-spike test — final.
#
# Verifies what actually works in cache-handler v0.16.0 + FrankenPHP + Redis:
#   1. /healthz returns 200.
#   2. .php whitelist returns 404 for non-allowed paths.
#   3. First GET is a cache MISS, second is a HIT.
#   4. Redis is the actual backend (Cache-Status reports detail=REDIS).
#   5. Surrogate-Key index populated in Redis (SURROGATE_<tag>).
#   6. Direct Redis DEL invalidates the cache entry — the pattern the
#      fp-mu-plugin's SouinInvalidator will use, because Souin's
#      documented HTTP invalidation APIs (PURGE, POST-CRUD, /souin-api
#      admin) are broken in cache-handler v0.16.0. See PHASE-0.md for
#      the investigation log.
#   7. Independent post tags cache without interference.

set -euo pipefail

BASE=${BASE:-http://localhost:8080}
COMPOSE=${COMPOSE:-docker compose}

pass() { printf '\033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✘\033[0m %s\n' "$1"; exit 1; }

dump_headers() {
    curl -sS -D - -o /dev/null "$@"
}

# Start with a clean cache so prior test runs don't pollute results.
$COMPOSE exec -T redis redis-cli FLUSHALL >/dev/null
pass "redis flushed"

# 1. healthz
hz=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/healthz") || fail "healthz curl failed"
[ "$hz" = "200" ] || fail "healthz expected 200, got $hz"
pass "healthz returns 200"

# 2. .php whitelist
forbidden=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/some-uploaded-file.php") || true
[ "$forbidden" = "404" ] || fail ".php whitelist expected 404 for /some-uploaded-file.php, got $forbidden"
pass ".php whitelist blocks /some-uploaded-file.php"

# 3. First request — expect MISS / stored
first=$(dump_headers "$BASE/post/1")
echo "$first" | grep -iE 'cache-status' | grep -qiE 'miss|stored' || fail "first /post/1 not a MISS"
pass "first GET /post/1 is a cache MISS"

# 4. Second request — expect HIT
sleep 0.2
second=$(dump_headers "$BASE/post/1")
echo "$second" | grep -iE 'cache-status' | grep -qi 'hit' || fail "second /post/1 not a HIT"
pass "second GET /post/1 is a cache HIT"

# Confirm Redis is the storage backend (not the in-memory fallback).
echo "$second" | grep -iE 'cache-status' | grep -qi 'detail=REDIS' || \
    fail "Cache-Status missing 'detail=REDIS' — Souin may have fallen back to in-memory storage"
pass "Redis backend confirmed (Cache-Status reports detail=REDIS)"

# 5. Surrogate-Key index populated
keys=$($COMPOSE exec -T redis redis-cli KEYS 'SURROGATE_*' 2>&1)
echo "$keys" | grep -q 'SURROGATE_' || fail "no SURROGATE_* keys in Redis"
count=$(echo "$keys" | wc -l | tr -d ' ')
pass "Surrogate-Key index populated in Redis ($count entries)"

# 6. Direct Redis DEL invalidates the cache entry — the pattern the
# mu-plugin's SouinInvalidator will use.
$COMPOSE exec -T redis redis-cli DEL \
    'GET-http-localhost:8080-/post/1' \
    'IDX_GET-http-localhost:8080-/post/1' >/dev/null
sleep 0.2
after_del=$(dump_headers "$BASE/post/1")
echo "$after_del" | grep -iE 'cache-status' | grep -qiE 'miss|stored' || \
    fail "after direct Redis DEL, /post/1 should be MISS"
pass "direct Redis DEL invalidates cache entry (mu-plugin invalidation path)"

# 7. Independent post tags
first2=$(dump_headers "$BASE/post/2")
echo "$first2" | grep -iE 'cache-status' | grep -qiE 'miss|stored' || fail "first /post/2 not a MISS"
sleep 0.2
second2=$(dump_headers "$BASE/post/2")
echo "$second2" | grep -iE 'cache-status' | grep -qi 'hit' || fail "second /post/2 not a HIT"
pass "/post/2 caches independently of /post/1"

# 8-11. Cacheability bypass — assert auth-aware paths and auth-cookied
# requests are never stored in Souin's Redis. The bodies should also
# differ between two consecutive requests (proves the response is
# rebuilt rather than served from any cache layer).
assert_not_cached() {
    local label="$1" url="$2"
    shift 2
    local first
    first=$(curl -sS "$@" "$url")
    sleep 0.2
    local second
    second=$(curl -sS "$@" "$url")
    if [ "$first" = "$second" ]; then
        fail "$label: response identical across requests — cache bypass not honoured"
    fi
    pass "$label: response rebuilt (cache bypassed)"
}

assert_no_redis_key() {
    local label="$1" path="$2"
    local key="GET-http-localhost:8080-${path}"
    if $COMPOSE exec -T redis redis-cli EXISTS "$key" | grep -q '^1$'; then
        fail "$label: Redis key '$key' exists — bypass not honoured"
    fi
    pass "$label: no Redis key for '$path' (bypass honoured)"
}

assert_not_cached "wp-admin path"           "$BASE/wp-admin/edit.php"
assert_no_redis_key "wp-admin path"         "/wp-admin/edit.php"

assert_not_cached "Bedrock /wp/wp-admin"    "$BASE/wp/wp-admin/edit.php"
assert_no_redis_key "Bedrock /wp/wp-admin"  "/wp/wp-admin/edit.php"

assert_not_cached "wp-login.php"            "$BASE/wp-login.php"
assert_no_redis_key "wp-login.php"          "/wp-login.php"

assert_not_cached "wp-json REST"            "$BASE/wp-json/wp/v2/posts"
assert_no_redis_key "wp-json REST"          "/wp-json/wp/v2/posts"

# `xmlrpc.php` is in the cache `regex.exclude` list, but in this harness
# it's also blocked by the .php whitelist (Caddy responds 404 before
# reaching the cache layer). Nothing dynamic to compare bodies against,
# so we skip the runtime assertion. Downstream sites that whitelist
# xmlrpc.php (legacy clients) still benefit from the bypass rule.

# Cookie-based bypass — same anonymous URL becomes uncacheable when
# the request carries a WP auth or per-user state cookie.
assert_not_cached "wordpress_logged_in_*"   "$BASE/post/99" -H 'Cookie: wordpress_logged_in_abc123=fake'
assert_not_cached "wp-postpass_*"           "$BASE/post/98" -H 'Cookie: wp-postpass_abc123=fake'
assert_not_cached "comment_author_*"        "$BASE/post/97" -H 'Cookie: comment_author_abc123=fake'

echo
pass "All Phase 0 cache assertions passed."
echo
echo "Notes for Phase 1:"
echo "  - SouinInvalidator must use direct Redis DEL (not HTTP API) for cache invalidation."
echo "  - Souin Redis key naming: GET-<scheme>-<host>-<path>, IDX_<...>, SURROGATE_<tag>."
echo "  - For tag-based bulk invalidation, read SURROGATE_<tag> to get the list of cached"
echo "    keys for that tag, then DEL all of them. The Redis SMEMBERS/SUNIONSTORE primitives"
echo "    plus a single DEL pipeline make this sub-millisecond."
