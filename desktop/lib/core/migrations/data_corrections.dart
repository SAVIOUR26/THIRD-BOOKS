// One-time, versioned data-correction migrations.
//
// Unlike the rest of the app, code in here is allowed to be tied to one
// specific historical incident and even to specific hardcoded record ids —
// that is the whole point. Each migration ships as a small bundled JSON
// asset (assets/migrations/*.json) describing an exact known-bad state and
// its correction. At startup, every value is checked against the CURRENT
// local data before anything is touched, so a migration is a safe no-op on
// any machine whose data doesn't match — a different install, or one
// already corrected some other way (e.g. a manual file swap done before
// this shipped). Applied migrations are recorded on disk so none of this
// ever runs twice.
//
// Each entry below should be deleted (and its asset file removed) once
// confirmed applied everywhere it needs to be — this is meant to be
// temporary, same as the emergency diagnostic endpoints elsewhere in this
// codebase (see sync-server/debug_log.php).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/journal_entry.dart';
import '../providers/depreciation_schedules_provider.dart';
import '../services/data_service.dart' show journalsProvider;
import '../services/local_storage_service.dart';

const _migrationAssetPaths = [
  'assets/migrations/depreciation_correction_2026_09.json',
];

Future<void> runDataCorrectionMigrations(Ref ref) async {
  final storage = LocalStorageService.instance;
  await storage.initialize();
  final applied = await storage.getAppliedMigrations();

  for (final assetPath in _migrationAssetPaths) {
    try {
      final raw = await rootBundle.loadString(assetPath);
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      final id = payload['id'] as String;
      if (applied.contains(id)) continue;

      await _applyDepreciationCorrection(ref, payload);
      await storage.markMigrationApplied(id);
    } catch (e) {
      // Never block app startup on this. Not marking as applied means it
      // simply gets re-evaluated (and re-attempted) on the next launch.
      debugPrint('Data-correction migration $assetPath failed, will retry next launch: $e');
    }
  }
}

Future<void> _applyDepreciationCorrection(Ref ref, Map<String, dynamic> payload) async {
  final journalsNotifier = ref.read(journalsProvider.notifier);
  final schedulesNotifier = ref.read(depreciationSchedulesProvider.notifier);

  await journalsNotifier.ready;
  await schedulesNotifier.ready;

  final currentEntryIds = ref.read(journalsProvider).entries.map((e) => e.id).toSet();
  final currentSchedulesById = {
    for (final s in ref.read(depreciationSchedulesProvider)) s.id: s,
  };

  // Only remove ids that are actually still present (already removed some
  // other way is a no-op, not an error) and only add entries whose id isn't
  // already there (so this is safe to evaluate even after a manual fix).
  final removeIds = ((payload['removeJournalEntryIds'] as List<dynamic>?) ?? [])
      .map((e) => e.toString())
      .where(currentEntryIds.contains)
      .toSet();

  final addEntries = ((payload['addJournalEntries'] as List<dynamic>?) ?? [])
      .map((j) => JournalEntry.fromJson(j as Map<String, dynamic>))
      .where((e) => !currentEntryIds.contains(e.id))
      .toList();

  // Only correct a schedule whose current book value still exactly matches
  // the known-bad figure this migration was written against. Matches the
  // already-corrected figure → leave it (already fixed some other way).
  // Matches neither → something else changed this schedule since the
  // incident was diagnosed; never guess, leave it alone for manual review
  // rather than silently overwriting a book value we can no longer verify.
  const epsilon = 1.0; // UGX — comfortably tighter than any real rounding drift
  final scheduleCorrections = <String, ({double currentValue, DateTime lastRunDate})>{};
  for (final u in (payload['scheduleUpdates'] as List<dynamic>? ?? [])) {
    final m = u as Map<String, dynamic>;
    final id = m['id'] as String;
    final schedule = currentSchedulesById[id];
    if (schedule == null) continue; // asset no longer exists here

    final expectedBad = (m['expectedBadCurrentValue'] as num).toDouble();
    if ((schedule.currentValue - expectedBad).abs() <= epsilon) {
      scheduleCorrections[id] = (
        currentValue: (m['correctedCurrentValue'] as num).toDouble(),
        lastRunDate: DateTime.parse(m['correctedLastRunDate'] as String),
      );
    }
  }

  if (removeIds.isNotEmpty) await journalsNotifier.removeEntries(removeIds);
  if (addEntries.isNotEmpty) await journalsNotifier.addEntries(addEntries);
  if (scheduleCorrections.isNotEmpty) {
    await schedulesNotifier.applyCorrections(scheduleCorrections);
  }
}
