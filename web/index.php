<?php

/**
 * Phase 0 spike — minimal test app.
 *
 * Pretends to be a "post page". Emits Surrogate-Key tags based on the URL
 * path so we can verify Souin's tag-based invalidation works:
 *
 *   GET /post/1     → Surrogate-Key: post-1 posts
 *   GET /post/2     → Surrogate-Key: post-2 posts
 *   GET /           → Surrogate-Key: home posts
 *
 * The page renders the current microsecond timestamp. If Souin is caching
 * correctly the timestamp will be frozen between requests until the cache
 * is invalidated by PURGE.
 */

$path = $_SERVER['REQUEST_URI'] ?? '/';
$path = parse_url($path, PHP_URL_PATH) ?: '/';

$keys = ['posts'];
if (preg_match('#^/post/(\d+)#', $path, $m)) {
    $keys[] = 'post-' . $m[1];
    $title = 'Post ' . $m[1];
} elseif ($path === '/') {
    $keys[] = 'home';
    $title = 'Home';
} else {
    $title = 'Page: ' . htmlspecialchars($path, ENT_QUOTES);
}

header('Content-Type: text/html; charset=utf-8');
header('Surrogate-Key: ' . implode(' ', $keys));
header('Cache-Control: public, s-maxage=300, max-age=60');

$now = sprintf('%.6f', microtime(true));

echo "<!doctype html><html><head><title>{$title}</title></head><body>";
echo "<h1>{$title}</h1>";
echo "<p>Surrogate-Key: <code>" . htmlspecialchars(implode(' ', $keys)) . "</code></p>";
echo "<p>Rendered at: <code id=\"ts\">{$now}</code></p>";
echo "<p>If this timestamp is frozen between page loads, Souin is serving from cache.</p>";
echo "</body></html>";
