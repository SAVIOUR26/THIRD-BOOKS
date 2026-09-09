<?php
// ── push.php — desktop app calls this on every launch ────────────────────────
// POST /push.php   Header: X-API-Key: <key>   Body: backup JSON

require 'config.php';

header('Content-Type: application/json');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    die(json_encode(['error' => 'POST required']));
}

if (($key = $_SERVER['HTTP_X_API_KEY'] ?? '') !== API_KEY) {
    http_response_code(401);
    die(json_encode(['error' => 'Unauthorized']));
}

$body = file_get_contents('php://input');
if (!$body) {
    http_response_code(400);
    die(json_encode(['error' => 'Empty body']));
}

// The desktop app gzips the backup before uploading — a real backup is
// mostly thousands of near-identical JSON records, which compresses by
// roughly 90%+ (measured: 26.3MB -> 1.8MB on a real production journals
// file), turning a marginal upload (timing out on a slow connection even
// with a generous ceiling) into a comfortable one. PHP does not
// auto-decompress a gzipped request body the way it can auto-compress
// responses, so this has to be done explicitly.
if (($_SERVER['HTTP_CONTENT_ENCODING'] ?? '') === 'gzip') {
    $decoded = @gzdecode($body);
    if ($decoded === false) {
        http_response_code(400);
        die(json_encode(['error' => 'Could not decompress gzip body']));
    }
    $body = $decoded;
}

$data = json_decode($body, true);
if (!$data || ($data['app'] ?? '') !== APP_TAG) {
    http_response_code(422);
    die(json_encode(['error' => 'Invalid ThirdBooks backup format']));
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

echo json_encode([
    'status'    => 'ok',
    'saved_at'  => date('c'),
    'records'   => $data['counts'] ?? [],
    'flagged'   => $flagged,
    'flag_reason' => $flagReason,
]);
