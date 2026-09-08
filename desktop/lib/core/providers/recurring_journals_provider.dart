import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/recurring_journal.dart';
import '../models/journal_entry.dart';
import '../services/local_storage_service.dart';
import '../../core/services/data_service.dart';

class RecurringJournalsState {
  final List<RecurringJournal> templates;
  final bool isLoading;

  const RecurringJournalsState({this.templates = const [], this.isLoading = false});

  RecurringJournalsState copyWith({List<RecurringJournal>? templates, bool? isLoading}) =>
      RecurringJournalsState(
        templates: templates ?? this.templates,
        isLoading: isLoading ?? this.isLoading,
      );
}

class RecurringJournalsNotifier extends StateNotifier<RecurringJournalsState> {
  final Ref _ref;
  LocalStorageService get _ls => LocalStorageService.instance;

  RecurringJournalsNotifier(this._ref) : super(const RecurringJournalsState()) {
    _load();
  }

  Future<void> _load() async {
    state = state.copyWith(isLoading: true);
    try {
      await _ls.initialize();
      final templates = await _ls.loadRecurringJournals();
      state = state.copyWith(templates: templates, isLoading: false);
    } catch (e) {
      debugPrint('Error loading recurring journals: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> addTemplate(RecurringJournal template) async {
    final updated = [...state.templates, template];
    state = state.copyWith(templates: updated);
    await _ls.saveRecurringJournals(updated);
  }

  Future<void> updateTemplate(RecurringJournal template) async {
    final updated = state.templates.map((t) => t.id == template.id ? template : t).toList();
    state = state.copyWith(templates: updated);
    await _ls.saveRecurringJournals(updated);
  }

  Future<void> deleteTemplate(String id) async {
    final updated = state.templates.where((t) => t.id != id).toList();
    state = state.copyWith(templates: updated);
    await _ls.saveRecurringJournals(updated);
  }

  Future<void> toggleActive(String id) async {
    final updated = state.templates.map((t) {
      if (t.id != id) return t;
      return t.copyWith(isActive: !t.isActive, updatedAt: DateTime.now());
    }).toList();
    state = state.copyWith(templates: updated);
    await _ls.saveRecurringJournals(updated);
  }

  Future<void> checkAndPostDue() async {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);

    final due = state.templates.where((t) =>
      t.isActive &&
      !t.isExpired &&
      !DateTime(t.nextRunDate.year, t.nextRunDate.month, t.nextRunDate.day)
          .isAfter(todayDate),
    ).toList();

    if (due.isEmpty) return;

    final journalsNotifier = _ref.read(journalsProvider.notifier);
    final now = DateTime.now();
    // Collect entries across all due templates and save once at the end —
    // see the same fix in depreciation_screen.dart / bank_reconciliation_
    // screen.dart for why calling addEntry() per item doesn't scale once
    // the journals file is large.
    final newEntries = <JournalEntry>[];

    for (final template in due) {
      const uuid = Uuid();
      final jeId = uuid.v4();
      final entryNumber = 'REC-${template.name.replaceAll(' ', '-').toUpperCase()}-'
          '${todayDate.year}${todayDate.month.toString().padLeft(2, '0')}';

      final entry = JournalEntry(
        id: jeId,
        entryNumber: entryNumber,
        date: todayDate,
        description: template.description,
        reference: template.reference ?? 'RECUR-${template.id.substring(0, 6)}',
        status: JournalEntryStatus.posted,
        recurringTemplateId: template.id,
        notes: 'Auto-posted from recurring template: ${template.name}',
        lines: template.lines.map((l) => JournalLine(
          id: '$jeId-${l.accountId}',
          journalEntryId: jeId,
          accountId: l.accountId,
          accountName: l.accountName,
          accountCode: l.accountCode,
          debit: l.debit,
          credit: l.credit,
          description: l.description,
        )).toList(),
        createdAt: now,
        updatedAt: now,
      );

      newEntries.add(entry);
      await updateTemplate(template.withNextRunAdvanced());
    }

    journalsNotifier.addEntries(newEntries);
  }
}

final recurringJournalsProvider =
    StateNotifierProvider<RecurringJournalsNotifier, RecurringJournalsState>(
  (ref) => RecurringJournalsNotifier(ref),
);
