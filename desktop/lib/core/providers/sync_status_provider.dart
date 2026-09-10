import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';
import '../services/server_sync_service.dart';
import '../services/local_storage_service.dart';
import '../services/data_service.dart' show databaseProvider;
import '../database/app_database.dart';
import 'recurring_journals_provider.dart';
import 'depreciation_schedules_provider.dart';
import '../migrations/data_corrections.dart';

class SyncStatusState {
  final bool isSyncing;
  final String? lastSyncAt;   // ISO-8601 string from secure storage
  final String? syncError;
  final bool needsInitialRestore;

  const SyncStatusState({
    this.isSyncing = false,
    this.lastSyncAt,
    this.syncError,
    this.needsInitialRestore = false,
  });

  SyncStatusState copyWith({
    bool? isSyncing,
    String? lastSyncAt,
    String? syncError,
    bool? needsInitialRestore,
    bool clearError = false,
  }) =>
      SyncStatusState(
        isSyncing:           isSyncing          ?? this.isSyncing,
        lastSyncAt:          lastSyncAt         ?? this.lastSyncAt,
        syncError:           clearError ? null  : (syncError ?? this.syncError),
        needsInitialRestore: needsInitialRestore ?? this.needsInitialRestore,
      );

  /// True when the last sync was less than 25 hours ago.
  bool get isFresh {
    if (lastSyncAt == null) return false;
    final dt = DateTime.tryParse(lastSyncAt!);
    if (dt == null) return false;
    return DateTime.now().difference(dt).inHours < 25;
  }

  /// True when last synced but more than 25 hours ago (stale).
  bool get isStale {
    if (lastSyncAt == null) return false;
    final dt = DateTime.tryParse(lastSyncAt!);
    if (dt == null) return false;
    return DateTime.now().difference(dt).inHours >= 25;
  }
}

class SyncStatusNotifier extends StateNotifier<SyncStatusState> {
  final Ref _ref;
  Timer? _timer;
  Timer? _heartbeatTimer;
  bool _loginHandled = false;

  SyncStatusNotifier(this._ref) : super(const SyncStatusState()) {
    _loadLastSync();

    // Watch auth state changes — start/stop periodic sync accordingly.
    _ref.listen<AuthState>(authStateProvider, (prev, next) {
      if (next.isAuthenticated && !(prev?.isAuthenticated ?? false)) {
        _handleLogin();
      } else if (!next.isAuthenticated && (prev?.isAuthenticated ?? false)) {
        _handleLogout();
      }
    });

    // Handle already-authenticated state (e.g., app restarted with saved session).
    Future.microtask(() {
      if (_ref.read(authStateProvider).isAuthenticated) {
        _handleLogin();
      }
    });
  }

  Future<void> _loadLastSync() async {
    final last = await ServerSyncService.getLastSyncedAt();
    if (mounted && last != null) {
      state = state.copyWith(lastSyncAt: last);
    }
  }

  Future<void> _handleLogin() async {
    if (_loginHandled) return;
    _loginHandled = true;

    await _checkNeedsInitialRestore();

    // Run once-off data-correction migrations before anything else touches
    // local data this session (a server restore, an auto-push, the
    // recurring/depreciation auto-post checks below). Gated the same way
    // as the push below: on a machine that still needs its initial restore,
    // local storage doesn't hold real data yet, so there is nothing correct
    // to evaluate against yet — this naturally re-runs on the next login,
    // once _checkNeedsInitialRestore sees the restored file has content.
    if (!state.needsInitialRestore) {
      await runDataCorrectionMigrations(_ref);
    }

    // Push immediately on login so a session that closes early still gets
    // backed up, instead of waiting for the first periodic tick.
    if (!state.needsInitialRestore) {
      _autoPush();
    }

    // Periodic push every 20 minutes while the app is running.
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 20), (_) => _autoPush());

    // Heartbeat every 10 minutes — send one immediately then on schedule.
    _sendHeartbeat();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 10), (_) => _sendHeartbeat());

    // Check and auto-post any due recurring journal templates.
    Future.microtask(() {
      if (mounted) _ref.read(recurringJournalsProvider.notifier).checkAndPostDue();
    });

    // Check and auto-post any depreciation/amortization schedules whose
    // period has genuinely ended — same automatic, no-manual-run pattern as
    // recurring journals above, so month-end depreciation posts itself the
    // next time the app is opened after the month closes.
    Future.microtask(() {
      if (mounted) _ref.read(depreciationSchedulesProvider.notifier).checkAndPostDue();
    });
  }

  void _handleLogout() {
    _timer?.cancel();
    _timer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _loginHandled = false;
    state = state.copyWith(needsInitialRestore: false);
  }

  /// Detect a fresh install with no local data — trigger automatic restore.
  ///
  /// Deliberately checks the file's raw bytes (dataFileHasContent), NOT
  /// loadJournalEntries().isEmpty. loadJournalEntries() returns an empty
  /// list both when the file genuinely has nothing AND when the file
  /// exists but failed to parse (corrupted) — those are very different
  /// situations. Treating a corrupted-but-present file as "no local data"
  /// would trigger a restore that silently overwrites it with whatever the
  /// server last has, which — a real production incident showed — can be
  /// weeks or months out of date. A genuinely fresh machine has nothing to
  /// lose from that; a machine with a corrupted file might have real,
  /// still-partially-recoverable data that a stale restore would destroy.
  Future<void> _checkNeedsInitialRestore() async {
    try {
      final ls = LocalStorageService.instance;
      await ls.initialize();
      final hasContent = await ls.dataFileHasContent('journals');
      if (!hasContent && mounted) {
        state = state.copyWith(needsInitialRestore: true);
      }
    } catch (_) {}
  }

  void _sendHeartbeat() {
    final userName = _ref.read(authStateProvider).user?.name ?? 'unknown';
    ServerSyncService.sendHeartbeat(userName);
  }

  /// Background push triggered by the periodic timer.
  Future<void> _autoPush() async {
    if (!mounted || state.isSyncing) return;
    // Reuse the app's single shared database connection — creating a fresh
    // AppDatabase() per push (as this used to) leaks a native SQLite
    // connection every time, since nothing ever closes it. With a push
    // firing every 20 minutes that adds up fast and was the likely cause
    // of sync silently degrading and eventually failing outright.
    final db = _ref.read(databaseProvider);
    await _push(db);
  }

  /// Manual push (called from UI or settings screen).
  Future<void> push() async {
    if (state.isSyncing) return;
    final db = _ref.read(databaseProvider);
    await _push(db);
  }

  Future<void> _push(AppDatabase db) async {
    if (!mounted) return;
    state = state.copyWith(isSyncing: true, clearError: true);
    final result = await ServerSyncService.pushBackup(db);
    if (!mounted) return;
    state = state.copyWith(
      isSyncing:  false,
      lastSyncAt: result.success ? result.syncedAt : state.lastSyncAt,
      syncError:  result.success ? null : result.error,
      clearError: result.success,
    );
  }

  /// Dismiss the initial-restore banner without restoring.
  void dismissRestorePrompt() {
    state = state.copyWith(needsInitialRestore: false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _heartbeatTimer?.cancel();
    super.dispose();
  }
}

final syncStatusProvider =
    StateNotifierProvider<SyncStatusNotifier, SyncStatusState>(
  (ref) => SyncStatusNotifier(ref),
);
