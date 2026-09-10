// Depreciation Schedules Provider
// Stores asset depreciation schedules locally with persistence.
// © 2026 ThirdBooks. All rights reserved.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../services/local_storage_service.dart';
import '../services/data_service.dart' show journalsProvider;
import '../models/journal_entry.dart';

// ---------------------------------------------------------------------------
// Standard default method/rate by asset category — matches URA capital
// allowance classes for tangible assets and typical useful-life-based
// straight-line rates for intangibles (IAS 38). Shared by both the
// automatic on-confirm schedule creation and the manual bulk-setup tool
// so they always agree.
// ---------------------------------------------------------------------------
({String method, double rate}) defaultDepreciationFor(String category) {
  switch (category) {
    case 'Electronics':
      return (method: 'declining_balance', rate: 40.0);
    case 'Vehicle':
      return (method: 'declining_balance', rate: 35.0);
    case 'Machinery':
      return (method: 'declining_balance', rate: 30.0);
    case 'Equipment':
    case 'Furniture':
      return (method: 'declining_balance', rate: 20.0);
    case 'Building':
      return (method: 'straight_line', rate: 5.0);
    case 'Software':
    case 'License':
      return (method: 'straight_line', rate: 33.33);
    case 'Patent':
    case 'Trademark':
      return (method: 'straight_line', rate: 20.0);
    case 'Goodwill':
      return (method: 'straight_line', rate: 10.0);
    default:
      return (method: 'declining_balance', rate: 20.0);
  }
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------
class DepreciationSchedule {
  final String id;
  final String assetDraftId;
  final String assetName;
  final String assetCategory;
  final double assetValue; // original purchase value
  final double currentValue; // book value after depreciation
  final String method; // 'declining_balance' | 'straight_line'
  final double rate; // annual percentage e.g. 20.0
  final String period; // 'monthly' | 'yearly'
  final DateTime startDate;
  final DateTime? lastRunDate;
  final bool isActive;
  final DateTime createdAt;

  const DepreciationSchedule({
    required this.id,
    required this.assetDraftId,
    required this.assetName,
    required this.assetCategory,
    required this.assetValue,
    required this.currentValue,
    required this.method,
    required this.rate,
    required this.period,
    required this.startDate,
    this.lastRunDate,
    this.isActive = true,
    required this.createdAt,
  });

  // ── Computed values ────────────────────────────────────────────────────────

  double get accumulatedDepreciation => assetValue - currentValue;

  double get percentageDepreciated =>
      assetValue > 0 ? (accumulatedDepreciation / assetValue) * 100 : 0;

  /// Live, unposted estimate of total depreciation accrued from [startDate]
  /// up to [asOf] — independent of whether "Run"/"Generate Entries" has
  /// actually been clicked yet. Simulates forward period-by-period using
  /// the same math as the real posting logic, without mutating currentValue
  /// or lastRunDate. This is what the Asset Register displays, so
  /// Accumulated Depreciation always shows a correct current figure
  /// instead of staying blank until someone manually posts entries.
  double accumulatedAsOf(DateTime asOf) {
    if (asOf.isBefore(startDate)) return 0.0;

    double simulatedValue = currentValue;
    double totalAccrued = accumulatedDepreciation; // whatever is already actually posted
    DateTime from = lastRunDate == null ? startDate : nextRunDate;

    while (simulatedValue > 0) {
      final periodEnd = periodEndDate(period, from);
      final segmentEnd = periodEnd.isAfter(asOf) ? asOf : periodEnd;
      if (from.isAfter(segmentEnd)) break;

      final days = segmentEnd.difference(from).inDays + 1;
      const daysInYear = 365.0;
      final dailyRate = rate / 100 / daysInYear;
      final baseValue = method == 'declining_balance' ? simulatedValue : assetValue;
      final dep = (baseValue * dailyRate * days).clamp(0.0, simulatedValue);

      totalAccrued += dep;
      simulatedValue -= dep;

      if (!periodEnd.isAfter(asOf)) {
        from = period == 'monthly'
            ? DateTime(periodEnd.year, periodEnd.month + 1, 1)
            : DateTime(periodEnd.year + 1, 1, 1);
      } else {
        break; // reached asOf mid-period
      }
    }

    return totalAccrued.clamp(0.0, assetValue);
  }

  // Returns the last calendar day of the period that starts on [from].
  // Monthly → last day of [from]'s month. Yearly → Dec 31 of [from]'s year.
  static DateTime periodEndDate(String period, DateTime from) {
    return period == 'monthly'
        ? DateTime(from.year, from.month + 1, 0) // day 0 of next month = last day of this month
        : DateTime(from.year, 12, 31);
  }

  // Pro-rata depreciation using daily rate over the exact days in [from..to].
  double depreciationForPeriod(DateTime from, DateTime to) {
    final days = to.difference(from).inDays + 1;
    const daysInYear = 365.0;
    final dailyRate = rate / 100 / daysInYear;
    final baseValue = method == 'declining_balance' ? currentValue : assetValue;
    return (baseValue * dailyRate * days).clamp(0.0, currentValue);
  }

  // Next period's pro-rata depreciation (used for display in UI cards).
  double get nextDepreciation {
    final from = nextRunDate;
    final to = DepreciationSchedule.periodEndDate(period, from);
    return depreciationForPeriod(from, to);
  }

  // First period: starts at purchase date.
  // Subsequent periods: always the 1st of the next calendar month/year so
  // that each period covers a full calendar month after the first partial one.
  DateTime get nextRunDate {
    if (lastRunDate == null) return startDate;
    return period == 'monthly'
        ? DateTime(lastRunDate!.year, lastRunDate!.month + 1, 1)
        : DateTime(lastRunDate!.year + 1, 1, 1);
  }

  // A period only becomes due once it has actually finished — checking
  // nextRunDate alone (the period's START) meant a schedule read as "due"
  // for its entire span, including the very first day. That let a whole
  // month get posted, pro-rated for its full span end-to-end, before that
  // span was even half over: e.g. opening the app on 10 Sept and posting a
  // "Sep 2026" entry as if the month had already closed. Requiring the
  // period's END date to have passed is what "runs automatically at
  // month-end" actually means — nothing for a month posts until that month
  // is over, whether triggered manually or by the automatic check.
  bool get isDue =>
      !DepreciationSchedule.periodEndDate(period, nextRunDate)
          .isAfter(DateTime.now());

  // [forDate] should be the LAST day of the period (periodEndDate) so that the
  // next nextRunDate advances to the 1st of the following month.
  // [amount] is the pre-computed pro-rata depreciation for the period.
  DepreciationSchedule applyDepreciation([DateTime? forDate, double? amount]) {
    final dep = amount ?? nextDepreciation;
    final newValue = (currentValue - dep).clamp(0.0, assetValue);
    return copyWith(currentValue: newValue, lastRunDate: forDate ?? DateTime.now());
  }

  DepreciationSchedule copyWith({
    double? currentValue,
    DateTime? lastRunDate,
    bool? isActive,
  }) =>
      DepreciationSchedule(
        id: id,
        assetDraftId: assetDraftId,
        assetName: assetName,
        assetCategory: assetCategory,
        assetValue: assetValue,
        currentValue: currentValue ?? this.currentValue,
        method: method,
        rate: rate,
        period: period,
        startDate: startDate,
        lastRunDate: lastRunDate ?? this.lastRunDate,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'assetDraftId': assetDraftId,
        'assetName': assetName,
        'assetCategory': assetCategory,
        'assetValue': assetValue,
        'currentValue': currentValue,
        'method': method,
        'rate': rate,
        'period': period,
        'startDate': startDate.toIso8601String(),
        'lastRunDate': lastRunDate?.toIso8601String(),
        'isActive': isActive,
        'createdAt': createdAt.toIso8601String(),
      };

  factory DepreciationSchedule.fromJson(Map<String, dynamic> j) =>
      DepreciationSchedule(
        id: j['id'] as String,
        assetDraftId: j['assetDraftId'] as String,
        assetName: j['assetName'] as String,
        assetCategory: j['assetCategory'] as String? ?? '',
        assetValue: (j['assetValue'] as num).toDouble(),
        currentValue: (j['currentValue'] as num).toDouble(),
        method: j['method'] as String,
        rate: (j['rate'] as num).toDouble(),
        period: j['period'] as String,
        startDate: DateTime.parse(j['startDate'] as String),
        lastRunDate: j['lastRunDate'] != null
            ? DateTime.parse(j['lastRunDate'] as String)
            : null,
        isActive: j['isActive'] as bool? ?? true,
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

// Returns true for IAS 38 intangible categories (amortized, not depreciated).
bool _isIntangibleCategory(String category) {
  final c = category.toLowerCase();
  return c == 'software' || c == 'license' || c == 'licence' ||
         c == 'patent' || c == 'trademark' || c == 'goodwill' ||
         c == 'intangible';
}

// Expense account for the DR leg: Depreciation (143) for tangibles,
// Amortization Expense (180) for intangibles.
String _expenseAccountId(String category) =>
    _isIntangibleCategory(category) ? 'acct-180' : 'acct-143';
String _expenseAccountCode(String category) =>
    _isIntangibleCategory(category) ? '180' : '143';
String _expenseAccountName(String category) =>
    _isIntangibleCategory(category) ? 'Amortization Expense' : 'Depreciation';

// Maps asset category to the accumulated contra-asset account for the CR leg.
// Intangibles → 1800/1810/1820; tangibles → 155/157/159.
String _accumDeprecAccountId(String category) {
  if (_isIntangibleCategory(category)) {
    final c = category.toLowerCase();
    if (c == 'software' || c == 'license' || c == 'licence') return 'acct-1810';
    if (c == 'patent' || c == 'trademark') return 'acct-1820';
    return 'acct-1800'; // Goodwill / Intangible default
  }
  final c = category.toLowerCase();
  if (c.contains('computer') || c.contains('hardware') ||
      c.contains('electronic')) {
    return 'acct-157'; // Less Accum. Depreciation — Computer Equipment
  }
  if (c.contains('furniture') || c.contains('fitting')) {
    return 'acct-159'; // Less Accum. Depreciation — Office Furniture
  }
  return 'acct-155'; // Less Accum. Depreciation — Office Equipment (default)
}

String _accumDeprecAccountCode(String category) {
  if (_isIntangibleCategory(category)) {
    final c = category.toLowerCase();
    if (c == 'software' || c == 'license' || c == 'licence') return '1810';
    if (c == 'patent' || c == 'trademark') return '1820';
    return '1800';
  }
  final c = category.toLowerCase();
  if (c.contains('computer') || c.contains('hardware') ||
      c.contains('electronic')) return '157';
  if (c.contains('furniture') || c.contains('fitting')) return '159';
  return '155';
}

String _accumDeprecAccountName(String category) {
  if (_isIntangibleCategory(category)) {
    final c = category.toLowerCase();
    if (c == 'software' || c == 'license' || c == 'licence') {
      return 'Accumulated Amortization - Software';
    }
    if (c == 'patent' || c == 'trademark') {
      return 'Accumulated Amortization - Patents';
    }
    return 'Accumulated Amortization';
  }
  final c = category.toLowerCase();
  if (c.contains('computer') || c.contains('hardware') ||
      c.contains('electronic')) {
    return 'Less Accum. Depreciation — Computer Equipment';
  }
  if (c.contains('furniture') || c.contains('fitting')) {
    return 'Less Accum. Depreciation — Office Furniture';
  }
  return 'Less Accum. Depreciation — Office Equipment';
}

/// Result of a posting run — the manual UI turns this into a snackbar; the
/// automatic on-login check just uses `posted` to decide whether anything
/// changed worth telling the app shell about.
class DepreciationPostResult {
  final int posted;
  final List<String> skipped;
  const DepreciationPostResult({required this.posted, required this.skipped});
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------
class DepreciationSchedulesNotifier
    extends StateNotifier<List<DepreciationSchedule>> {
  final LocalStorageService _storage;
  final Ref _ref;

  // Resolves once the initial load from disk is done — other providers
  // (e.g. AssetDraftsNotifier's backfill) must await this before checking
  // "does a schedule already exist", or they'd race an empty in-flight
  // load and create duplicates.
  final Completer<void> _loadCompleter = Completer<void>();
  Future<void> get ready => _loadCompleter.future;

  DepreciationSchedulesNotifier(this._storage, this._ref) : super([]) {
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _storage.loadData(
          'depreciation_schedules', DepreciationSchedule.fromJson);
      state = list;
    } catch (_) {
    } finally {
      if (!_loadCompleter.isCompleted) _loadCompleter.complete();
    }
  }

  Future<void> _save() async {
    await _storage.saveData(
        'depreciation_schedules', state, (s) => s.toJson());
  }

  Future<void> add(DepreciationSchedule schedule) async {
    state = [schedule, ...state];
    await _save();
  }

  Future<void> runDepreciation(String id) async {
    state = state.map((s) {
      if (s.id != id) return s;
      final from = s.nextRunDate;
      final to   = DepreciationSchedule.periodEndDate(s.period, from);
      return s.applyDepreciation(to, s.depreciationForPeriod(from, to));
    }).toList();
    await _save();
  }

  Future<void> toggleActive(String id) async {
    state = state
        .map((s) => s.id == id ? s.copyWith(isActive: !s.isActive) : s)
        .toList();
    await _save();
  }

  Future<void> remove(String id) async {
    state = state.where((s) => s.id != id).toList();
    await _save();
  }

  /// The total posted debit activity against [expenseAccountCode] within
  /// [periodStart]..[periodEnd] — i.e. depreciation/amortization for this
  /// exact month already exists in the ledger, most likely from an earlier
  /// manual journal entry predating this per-asset schedule system. Used to
  /// stop a run from ever posting a duplicate on top of it. Returns null if
  /// nothing matched, so the caller can tell "not recorded" apart from
  /// "recorded, and it was exactly UGX 0" (which never happens in practice,
  /// but null is the honest way to express "no match").
  double? _periodAlreadyRecordedAmount(List<JournalEntry> allEntries,
      String expenseAccountCode, DateTime periodStart, DateTime periodEnd) {
    double? total;
    for (final e in allEntries) {
      if (e.status != JournalEntryStatus.posted) continue;
      if (e.date.isBefore(periodStart) || e.date.isAfter(periodEnd)) continue;
      for (final line in e.lines) {
        if (line.accountCode == expenseAccountCode && line.debit > 0) {
          total = (total ?? 0) + line.debit;
        }
      }
    }
    return total;
  }

  /// Posts journal entries for every overdue period on every schedule in
  /// [due], back-filling multiple missed months per asset in one run if
  /// needed. Shared by the manual "Run Now" / "Generate Entries" UI actions
  /// and by [checkAndPostDue]'s automatic month-end check — both call this
  /// so the posting logic (and its duplicate-period guard) only exists once.
  Future<DepreciationPostResult> postDepreciationFor(
      List<DepreciationSchedule> due) async {
    final journalsNotifier = _ref.read(journalsProvider.notifier);

    // Wait for the real journal history to finish loading before reading it
    // for the duplicate-period check below, or building the batch to post.
    // JournalsNotifier starts empty and loads a possibly 20MB+ file in the
    // background; reading it too early here previously meant both the
    // duplicate-check silently saw nothing AND the batch save that follows
    // overwrote the entire real journals file with just this run's new
    // entries — reproduced live as "reports blank, bank balance disappeared"
    // right after running depreciation as the first action after opening.
    await journalsNotifier.ready;

    final allEntries = _ref.read(journalsProvider).entries;
    // Collect every period's entry across every asset here, then save ONCE
    // at the end via addEntries() — calling addEntry() per period, per
    // asset, meant a full read-modify-write of the entire journals file on
    // every single one. Harmless on a small file, but with tens of
    // thousands of existing entries, back-filling several overdue months
    // across several assets meant dozens of full read+decode+encode+write
    // cycles of a many-MB file in rapid succession — slow enough to look
    // like the run had corrupted something afterward.
    final newEntries = <JournalEntry>[];
    int posted = 0;
    final skipped = <String>[];
    final updated = <String, DepreciationSchedule>{};

    for (final schedule in due) {
      DepreciationSchedule current = schedule;
      final expenseCode = _expenseAccountCode(schedule.assetCategory);

      // Back-fill every overdue period, each with its own JE dated at the period.
      // Pro-rata: first period covers purchase date → end of that month;
      // subsequent periods cover the full calendar month (1st → last day).
      while (current.isDue) {
        final periodDate = current.nextRunDate;
        final periodEnd  = DepreciationSchedule.periodEndDate(current.period, periodDate);
        final amount     = current.depreciationForPeriod(periodDate, periodEnd);
        if (amount <= 0) break;

        final periodLabel = DateFormat('MMM yyyy').format(periodDate);

        // Depreciation for this exact month already exists in the ledger
        // (typically an earlier manual entry) — never post a duplicate on
        // top of it. Skip creating a new entry, but still reduce
        // currentValue by the amount that WAS already recorded — not by
        // zero — before advancing past this period.
        final alreadyRecorded =
            _periodAlreadyRecordedAmount(allEntries, expenseCode, periodDate, periodEnd);
        if (alreadyRecorded != null) {
          skipped.add('${schedule.assetName} — $periodLabel');
          current = current.applyDepreciation(periodEnd, alreadyRecorded);
          continue;
        }

        final jeId = const Uuid().v4();
        final isIntangible = _isIntangibleCategory(schedule.assetCategory);
        newEntries.add(JournalEntry(
          id: jeId,
          entryNumber: '${isIntangible ? 'AMRT' : 'DEP'}-${schedule.assetName.replaceAll(' ', '-').toUpperCase()}-$periodLabel',
          date: periodDate,
          description: '${isIntangible ? 'Amortization' : 'Depreciation'}: ${schedule.assetName} — $periodLabel',
          reference: '${isIntangible ? 'AMRT' : 'DEPR'}-${schedule.id.substring(0, 6).toUpperCase()}',
          status: JournalEntryStatus.posted,
          lines: [
            JournalLine(
              id: '$jeId-1',
              journalEntryId: jeId,
              accountId: _expenseAccountId(schedule.assetCategory),
              accountCode: expenseCode,
              accountName: _expenseAccountName(schedule.assetCategory),
              debit: amount,
              credit: 0,
            ),
            JournalLine(
              id: '$jeId-2',
              journalEntryId: jeId,
              accountId: _accumDeprecAccountId(schedule.assetCategory),
              accountCode: _accumDeprecAccountCode(schedule.assetCategory),
              accountName: _accumDeprecAccountName(schedule.assetCategory),
              debit: 0,
              credit: amount,
            ),
          ],
          createdAt: periodDate,
          updatedAt: periodDate,
        ));

        // Store periodEnd as lastRunDate → nextRunDate becomes 1st of next month.
        current = current.applyDepreciation(periodEnd, amount);
        posted++;
      }

      updated[schedule.id] = current;
    }

    // One single state update + save for every schedule touched, and one
    // single save for every entry collected across every asset/period.
    if (updated.isNotEmpty) {
      state = state.map((s) => updated[s.id] ?? s).toList();
      await _save();
    }
    if (newEntries.isNotEmpty) {
      await journalsNotifier.addEntries(newEntries);
    }

    return DepreciationPostResult(posted: posted, skipped: skipped);
  }

  /// Automatic month-end check — mirrors RecurringJournalsNotifier's
  /// checkAndPostDue(), called on every login so depreciation/amortization
  /// posts itself once a period has genuinely ended, with no manual "Run"
  /// click required. Relies on DepreciationSchedule.isDue only turning true
  /// once the period's END date has passed (not merely its start), so this
  /// never posts a month before that month is actually over.
  Future<DepreciationPostResult> checkAndPostDue() async {
    await ready;
    final due = state.where((s) => s.isActive && s.isDue).toList();
    if (due.isEmpty) return const DepreciationPostResult(posted: 0, skipped: []);
    return postDepreciationFor(due);
  }

  /// Reload from disk after a server pull has overwritten the JSON file.
  Future<void> reload() => _load();

  /// Replace entire list (called after a server pull overwrites local storage).
  void replaceAll(List<DepreciationSchedule> schedules) {
    state = schedules;
    _save();
  }

  /// Clear all schedules — used by the settings "clear cache" action.
  Future<void> clearAll() async {
    state = [];
    await _save();
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------
final depreciationSchedulesProvider = StateNotifierProvider<
    DepreciationSchedulesNotifier, List<DepreciationSchedule>>(
  (ref) => DepreciationSchedulesNotifier(
      ref.read(localStorageServiceProvider), ref),
);
