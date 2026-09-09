<?php
// ── push.php — desktop app calls this on every launch ────────────────────────
// POST /push.php   Header: X-API-Key: <key>   Body: backup JSON

require 'config.php';

header('Content-Type: application/json');

// TEMPORARY diagnostic — a client is hitting a 500 whose actual error text
// never reaches the app in readable form, which the raw client-side
// exception shape suggests is a *second* failure: something (most likely a
// stray PHP notice/warning printed before our JSON, since display_errors
// can do that even inside a script that otherwise runs fine) is corrupting
// the response body enough that the client can't even parse out the error
// message we send. Buffering ALL output and logging anything unexpected
// lets us see the real cause without needing production credentials
// shared over chat. Remove this block (and debug_log.txt) once diagnosed —
// same one-off pattern as the emergency status.php endpoint used earlier.
ob_start();
$__debugLog = function ($label, $data = null) {
    $entry = '[' . date('c') . "] $label";
    if ($data !== null) $entry .= ': ' . (is_string($data) ? $data : json_encode($data));
    file_put_contents(__DIR__ . '/debug_log.txt', $entry . "\n", FILE_APPEND);
};
$__debugLog('--- push.php request ---');
$__debugLog('headers', [
    'content-encoding' => $_SERVER['HTTP_CONTENT_ENCODING'] ?? null,
    'content-length'   => $_SERVER['CONTENT_LENGTH'] ?? null,
    'content-type'     => $_SERVER['CONTENT_TYPE'] ?? null,
]);

// Every exit point goes through this instead of a bare die(json_encode(...))
// so stray buffered output (a PHP notice/warning printed before our JSON)
// gets caught and logged instead of silently corrupting the response body.
$__respond = function (int $code, array $payload) use ($__debugLog) {
    $stray = ob_get_clean();
    if ($stray !== '') $__debugLog('STRAY OUTPUT before response', substr($stray, 0, 2000));
    $__debugLog('RESPONSE ' . $code, $payload);
    http_response_code($code);
    echo json_encode($payload);
    exit;
};

// Safety net: this host gives no direct log access, so an unhandled error
// anywhere below would otherwise reach the app as a blank, undiagnosable
// 500. Since PHP 7, most fatals (undefined function, type errors, etc.)
// are catchable \Throwables — surface the real message instead of nothing.
set_exception_handler(function ($e) use ($__respond) {
    $__respond(500, ['error' => 'Unhandled server error: ' . $e->getMessage()]);
});

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    $__respond(405, ['error' => 'POST required']);
}

if (($key = $_SERVER['HTTP_X_API_KEY'] ?? '') !== API_KEY) {
    $__respond(401, ['error' => 'Unauthorized']);
}

$body = file_get_contents('php://input');
if (!$body) {
    $__respond(400, ['error' => 'Empty body']);
}

// The desktop app gzips the backup before uploading — a real backup is
// mostly thousands of near-identical JSON records, which compresses by
// roughly 90%+ (measured: 26.3MB -> 1.8MB on a real production journals
// file), turning a marginal upload (timing out on a slow connection even
// with a generous ceiling) into a comfortable one. PHP does not
// auto-decompress a gzipped request body the way it can auto-compress
// responses, so this has to be done explicitly.
if (($_SERVER['HTTP_CONTENT_ENCODING'] ?? '') === 'gzip') {
    $__debugLog('gzip body received', ['bytes' => strlen($body)]);
    if (!function_exists('gzdecode')) {
        $__respond(500, ['error' => 'Server PHP build is missing the zlib extension (gzdecode unavailable) — cannot decompress gzip uploads']);
    }
    $decoded = @gzdecode($body);
    if ($decoded === false) {
        $__respond(400, ['error' => 'Could not decompress gzip body']);
    }
    $__debugLog('gzip decoded ok', ['bytes' => strlen($decoded)]);
    $body = $decoded;
}

$data = json_decode($body, true);
if (!$data || ($data['app'] ?? '') !== APP_TAG) {
    $__debugLog('json_decode failed or wrong app tag', [
        'json_last_error' => json_last_error_msg(),
        'body_head'       => substr($body, 0, 300),
    ]);
    $__respond(422, ['error' => 'Invalid ThirdBooks backup format']);
}

if (!is_dir(BACKUP_DIR)) mkdir(BACKUP_DIR, 0755, true);

// ── Sanity guard against catastrophic data loss ──────────────────────────
// Journal entries in this app are only ever added or reversed, never bulk-
// deleted — so a huge drop in journal count versus the current backup is
// always abnormal, whatever caused it (a client bug, a bad restore, a race
// on save). This has happened more than once: a broken local state was
// pushed and silently became "latest", overwriting a good backup with no
// error anywhere. A push that looks like this is saved for forensics but
// kept OUT of the active/"latest" set, so the real backup history can
// never be corrupted by it again, regardless of what the client sends.
$incomingJournals = $data['counts']['journals'] ?? null;
$flagged = false;
$flagReason = null;

if ($incomingJournals !== null) {
    $activeFiles = glob(BACKUP_DIR . '*_backup.json') ?: [];
    rsort($activeFiles);
    $currentLatest = $activeFiles[0] ?? null;
    if ($currentLatest !== null) {
        $head = file_get_contents($currentLatest, false, null, 0, 8192);
        $currentJournals = null;
        if ($head !== false && preg_match('/"journals"\s*:\s*(\d+)/', $head, $m)) {
            $currentJournals = (int) $m[1];
        }
        if ($currentJournals !== null && $currentJournals >= 100 &&
            $incomingJournals < $currentJournals * 0.5) {
            $flagged = true;
            $flagReason = "journals dropped from $currentJournals to $incomingJournals";
        }
    }
}

if ($flagged) {
    $flaggedDir = BACKUP_DIR . 'flagged/';
    if (!is_dir($flaggedDir)) mkdir($flaggedDir, 0755, true);
    $filename = $flaggedDir . date('Y-m-d_H-i-s') . '_backup.json';
} else {
    $filename = BACKUP_DIR . date('Y-m-d_H-i-s') . '_backup.json';
}
file_put_contents($filename, $body);

// Prune oldest backups beyond MAX_BACKUPS (active set only — flagged pushes
// don't count against this and aren't auto-pruned).
if (!$flagged) {
    $files = glob(BACKUP_DIR . '*_backup.json');
    if ($files && count($files) > MAX_BACKUPS) {
        sort($files);
        foreach (array_slice($files, 0, count($files) - MAX_BACKUPS) as $old) {
            unlink($old);
        }
    }
}

$__respond(200, [
    'status'    => 'ok',
    'saved_at'  => date('c'),
    'records'   => $data['counts'] ?? [],
    'flagged'   => $flagged,
    'flag_reason' => $flagReason,
]);
