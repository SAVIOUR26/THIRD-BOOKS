<?php
// ── debug_log.php — TEMPORARY, read-only viewer for push.php's diagnostic
// log while tracking down a 500 error. Not protected by the real API key
// (deliberately, so no production secret needs to be shared to use it) —
// gated by a one-off token instead, and only exposes request metadata/error
// text, never backup contents. Delete this file once the issue is found.
header('Content-Type: text/plain');

if (($_GET['token'] ?? '') !== 'tmp-debug-2026-09-09') {
    http_response_code(403);
    die('forbidden');
}

$path = __DIR__ . '/debug_log.txt';
if (!file_exists($path)) {
    die('No debug_log.txt yet — trigger a sync from the app first.');
}

echo file_get_contents($path);
