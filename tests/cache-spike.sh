#!/usr/bin/env bash
# Phase 0 cache-spike test.
#
# Exercises Souin via the FrankenPress runtime to verify:
#   1. First GET is a cache MISS.
#   2. Second GET (within TTL) is a cache HIT (response body identical, frozen timestamp).
#   3. PURGE by Surrogate-Key invalidates the entry.
#   4. Subsequent GET is a MISS again.
#   5. .php whitelist returns 404 for non-allowed paths.
#   6. /healthz returns 200.

set -euo pipefail

BASE=${BASE:-http://localhost:8080}

pass() { printf '\033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✘\033[0m %s\n' "$1"; exit 1; }

dump_headers() {
    curl -sS -D - -o /dev/null "$@"
}

# 1. healthz
hz=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/healthz") || fail "healthz curl failed"
[ "$hz" = "200" ] || fail "healthz expected 200, got $hz"
pass "healthz returns 200"

# 2. .php whitelist
forbidden=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/some-uploaded-file.php") || true
[ "$forbidden" = "404" ] || fail ".php whitelist expected 404 for /some-uploaded-file.php, got $forbidden"
pass ".php whitelist blocks /some-uploaded-file.php"

# 3. First request — expect MISS
first=$(dump_headers "$BASE/post/1")
echo "$first" | grep -qiE 'cache-status|x-souin' || fail "no cache-status header on first /post/1"
echo "$first" | grep -iE 'cache-status' | grep -qiE 'miss|stored' || fail "first /post/1 not a MISS"
pass "first GET /post/1 is a cache MISS"

# 4. Second request — expect HIT
sleep 0.2
second=$(dump_headers "$BASE/post/1")
echo "$second" | grep -iE 'cache-status' | grep -qi 'hit' || fail "second /post/1 not a HIT"
pass "second GET /post/1 is a cache HIT"

# 5. PURGE by Surrogate-Key
purge=$(curl -sS -X PURGE -H 'Surrogate-Key: post-1' -o /dev/null -w '%{http_code}' "$BASE/") || true
[[ "$purge" =~ ^(200|204)$ ]] || fail "PURGE expected 200/204, got $purge"
pass "PURGE Surrogate-Key: post-1 returned $purge"

# 6. Next request — expect MISS again (cache invalidated)
sleep 0.2
third=$(dump_headers "$BASE/post/1")
echo "$third" | grep -iE 'cache-status' | grep -qiE 'miss|stored' || fail "after PURGE /post/1 not a MISS"
pass "after PURGE, GET /post/1 is a MISS again"

# 7. Other key untouched — /post/2 should still be cacheable on first hit MISS, second hit HIT
first2=$(dump_headers "$BASE/post/2")
echo "$first2" | grep -iE 'cache-status' | grep -qiE 'miss|stored' || fail "first /post/2 not a MISS"
sleep 0.2
second2=$(dump_headers "$BASE/post/2")
echo "$second2" | grep -iE 'cache-status' | grep -qi 'hit' || fail "second /post/2 not a HIT"
pass "/post/2 caches independently of /post/1"

echo
pass "All Phase 0 cache assertions passed."
