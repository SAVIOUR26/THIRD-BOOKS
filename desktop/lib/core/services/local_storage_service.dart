import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/account.dart';
import '../models/customer.dart';
import '../models/vendor.dart';
import '../models/invoice.dart';
import '../models/bill.dart';
import '../models/journal_entry.dart';
import '../models/payment.dart';
import '../models/bank_transaction.dart';
import '../models/credit_debit_note.dart';
import '../models/recurring_journal.dart';

// ============================================================================
// Local Storage Service - Persists data to local filesystem
// ============================================================================

/// Ground-truth report on a single data file, read directly off disk.
class DataFileDiagnosis {
  final String key;
  final bool exists;
  final int sizeBytes;
  final int? recordCount; // null if the file's JSON couldn't be parsed at all
  final String? parseError;

  DataFileDiagnosis({
    required this.key,
    required this.exists,
    required this.sizeBytes,
    required this.recordCount,
    this.parseError,
  });
}

class LocalStorageService {
  static LocalStorageService? _instance;
  late Directory _dataDir;
  bool _initialized = false;

  LocalStorageService._();

  static LocalStorageService get instance {
    _instance ??= LocalStorageService._();
    return _instance!;
  }

  Future<void> initialize() async {
    if (_initialized) return;

    final appDir = await getApplicationDocumentsDirectory();
    _dataDir = Directory('${appDir.path}/thirdbooks_data');

    if (!await _dataDir.exists()) {
      await _dataDir.create(recursive: true);
    }

    _initialized = true;
  }

  File _getFile(String name) {
    return File('${_dataDir.path}/$name.json');
  }

  /// True if the data file for [key] exists on disk and has real content —
  /// used by safety checks that must never mistake "this file failed to
  /// parse" for "this file genuinely has nothing in it." A parse failure
  /// (or any other transient read error) still leaves the file's actual
  /// bytes on disk untouched; this lets a caller tell that apart from a
  /// truly empty/missing file before deciding it's safe to overwrite.
  Future<bool> dataFileHasContent(String key) async {
    await initialize();
    final file = _getFile(key);
    if (!await file.exists()) return false;
    final len = await file.length();
    return len > 2; // more than just "[]"
  }

  /// Ground-truth inspection of a data file, independent of any model
  /// parsing or cached provider state — reads the file directly off disk
  /// right now and reports exactly what's there. Used by the "Diagnose &
  /// Refresh Local Data" tool so a blank screen can always be checked
  /// against reality instead of guessed at.
  Future<DataFileDiagnosis> diagnoseDataFile(String key) async {
    await initialize();
    final file = _getFile(key);
    if (!await file.exists()) {
      return DataFileDiagnosis(key: key, exists: false, sizeBytes: 0, recordCount: 0);
    }
    final sizeBytes = await file.length();
    try {
      final content = await file.readAsString();
      final jsonList = jsonDecode(content) as List<dynamic>;
      return DataFileDiagnosis(
        key: key, exists: true, sizeBytes: sizeBytes, recordCount: jsonList.length);
    } catch (e) {
      return DataFileDiagnosis(
        key: key, exists: true, sizeBytes: sizeBytes, recordCount: null, parseError: e.toString());
    }
  }

  // ============================================================================
  // Generic Save/Load Methods
  // ============================================================================

  Future<void> saveData<T>(String key, List<T> items, Map<String, dynamic> Function(T) toJson) async {
    await initialize();
    final file = _getFile(key);

    // Safety net: if a save is about to drastically shrink an existing
    // file (e.g. writing 1 record over 13,323), that is almost never an
    // intentional bulk delete — it's what happens when something upstream
    // failed to load the full dataset first, then saved its incomplete
    // in-memory state back over the real data. That exact sequence
    // permanently destroyed real production journal entries once already.
    // Back up the previous version before every such write so it is never
    // unrecoverable again — this never blocks the save itself.
    try {
      if (await file.exists()) {
        final existingRaw = await file.readAsString();
        final existingCount = (jsonDecode(existingRaw) as List).length;
        final droppedFraction =
            existingCount == 0 ? 0.0 : 1 - (items.length / existingCount);
        if (existingCount >= 20 && droppedFraction > 0.5) {
          final backupFile = File(
              '${file.path}.before-drop-${DateTime.now().millisecondsSinceEpoch}.bak');
          await backupFile.writeAsString(existingRaw);
          debugPrint(
              '$key: saving $existingCount -> ${items.length} records '
              '(>50% drop) — previous version backed up to ${backupFile.path}');
        }
      }
    } catch (_) {
      // Never let this safety check block a normal save.
    }

    final jsonList = items.map((item) => toJson(item)).toList();

    // Write to a sibling temp file, then rename it over the real one,
    // instead of writing the real file in place. A plain writeAsString()
    // is NOT atomic: if the app is killed mid-write — force-closed, a
    // crash, a power cut, Windows Update rebooting the machine — the file
    // is left truncated with invalid JSON. The read side then can't
    // parse it, silently returns "no records", and everything downstream
    // (reports, balances, the "no local data, restore from server?"
    // prompt) looks exactly like the data was lost, even though the real
    // data was never actually gone — just an interrupted write away from
    // unreadable. A rename onto an existing path is a single filesystem
    // operation: either the old file is still there, or the new one
    // fully is — never a half-written mix of both.
    final tmpFile = File('${file.path}.tmp');
    await tmpFile.writeAsString(jsonEncode(jsonList));
    await tmpFile.rename(file.path);
  }

  Future<List<T>> loadData<T>(String key, T Function(Map<String, dynamic>) fromJson) async {
    await initialize();
    final file = _getFile(key);

    if (!await file.exists()) {
      return [];
    }

    List<dynamic> jsonList;
    try {
      final content = await file.readAsString();
      jsonList = jsonDecode(content) as List<dynamic>;
    } catch (e) {
      // The top-level JSON itself is invalid — most likely a write that
      // was interrupted partway (before saveData() above made writes
      // atomic) rather than genuinely empty data. Never just drop the
      // file and move on: preserve the raw bytes next to it so whatever
      // is recoverable in them isn't lost to the next normal save
      // overwriting this path, and log loudly enough that "the file on
      // disk has real content but the app returned nothing" is
      // diagnosable instead of looking identical to actual data loss.
      debugPrint('Error loading $key: $e');
      try {
        final preserved = File(
            '${file.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}.bak');
        await preserved.writeAsBytes(await file.readAsBytes());
        debugPrint('$key: could not parse — original bytes preserved at ${preserved.path}');
      } catch (_) {
        // Preservation is best-effort — never let it block the app from
        // continuing to start up.
      }
      return [];
    }

    // Parse each record independently so one malformed record can't wipe
    // out every other record in the file. A single bad journal entry used
    // to make ALL journal entries disappear from the app — the file on
    // disk was fine, but the read returned an empty list, which looked
    // exactly like "all my data is gone" with no error shown anywhere.
    final items = <T>[];
    var skipped = 0;
    for (final json in jsonList) {
      try {
        items.add(fromJson(json as Map<String, dynamic>));
      } catch (e) {
        skipped++;
        debugPrint('Skipped one bad $key record: $e');
      }
    }
    if (skipped > 0) {
      debugPrint('$key: loaded ${items.length}, skipped $skipped malformed record(s)');
    }
    return items;
  }

  // ============================================================================
  // Specific Entity Methods
  // ============================================================================

  Future<void> saveAccounts(List<Account> accounts) async {
    await saveData('accounts', accounts, (a) => a.toJson());
  }

  Future<List<Account>> loadAccounts() async {
    return loadData('accounts', Account.fromJson);
  }

  Future<void> saveCustomers(List<Customer> customers) async {
    await saveData('customers', customers, (c) => c.toJson());
  }

  Future<List<Customer>> loadCustomers() async {
    return loadData('customers', Customer.fromJson);
  }

  Future<void> saveVendors(List<Vendor> vendors) async {
    await saveData('vendors', vendors, (v) => v.toJson());
  }

  Future<List<Vendor>> loadVendors() async {
    return loadData('vendors', Vendor.fromJson);
  }

  Future<void> saveInvoices(List<Invoice> invoices) async {
    await saveData('invoices', invoices, (i) => i.toJson());
  }

  Future<List<Invoice>> loadInvoices() async {
    return loadData('invoices', Invoice.fromJson);
  }

  Future<void> saveBills(List<Bill> bills) async {
    await saveData('bills', bills, (b) => b.toJson());
  }

  Future<List<Bill>> loadBills() async {
    return loadData('bills', Bill.fromJson);
  }

  Future<void> saveJournalEntries(List<JournalEntry> entries) async {
    await saveData('journals', entries, (e) => e.toJson());
  }

  Future<List<JournalEntry>> loadJournalEntries() async {
    return loadData('journals', JournalEntry.fromJson);
  }

  Future<void> savePayments(List<Payment> payments) async {
    await saveData('payments', payments, (p) => p.toJson());
  }

  Future<List<Payment>> loadPayments() async {
    return loadData('payments', Payment.fromJson);
  }

  Future<void> saveBankTransactions(List<BankTransaction> txns) async {
    await saveData('bank_transactions', txns, (t) => t.toJson());
  }

  Future<List<BankTransaction>> loadBankTransactions() async {
    return loadData('bank_transactions', BankTransaction.fromJson);
  }

  Future<void> saveOutletSettlements(List<OutletSettlement> settlements) async {
    await saveData('outlet_settlements', settlements, (s) => s.toJson());
  }

  Future<List<OutletSettlement>> loadOutletSettlements() async {
    return loadData('outlet_settlements', OutletSettlement.fromJson);
  }

  Future<void> saveCreditNotes(List<CreditNote> notes) async {
    await saveData('credit_notes', notes, (n) => n.toJson());
  }

  Future<List<CreditNote>> loadCreditNotes() async {
    return loadData('credit_notes', CreditNote.fromJson);
  }

  Future<void> saveDebitNotes(List<DebitNote> notes) async {
    await saveData('debit_notes', notes, (n) => n.toJson());
  }

  Future<List<DebitNote>> loadDebitNotes() async {
    return loadData('debit_notes', DebitNote.fromJson);
  }

  Future<void> saveRecurringJournals(List<RecurringJournal> items) async {
    await saveData('recurring_journals', items, (r) => r.toJson());
  }

  Future<List<RecurringJournal>> loadRecurringJournals() async {
    return loadData('recurring_journals', RecurringJournal.fromJson);
  }

  // ============================================================================
  // Sync Queue Management
  // ============================================================================

  Future<void> addToSyncQueue(SyncQueueItem item) async {
    await initialize();
    final queue = await loadSyncQueue();
    queue.add(item);
    await _saveSyncQueue(queue);
  }

  Future<List<SyncQueueItem>> loadSyncQueue() async {
    await initialize();
    final file = _getFile('sync_queue');

    if (!await file.exists()) {
      return [];
    }

    try {
      final content = await file.readAsString();
      final jsonList = jsonDecode(content) as List<dynamic>;
      return jsonList.map((json) => SyncQueueItem.fromJson(json as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('Error loading sync queue: $e');
      return [];
    }
  }

  Future<void> _saveSyncQueue(List<SyncQueueItem> queue) async {
    final file = _getFile('sync_queue');
    final jsonList = queue.map((item) => item.toJson()).toList();
    await file.writeAsString(jsonEncode(jsonList));
  }

  Future<void> removeFromSyncQueue(String itemId) async {
    final queue = await loadSyncQueue();
    queue.removeWhere((item) => item.id == itemId);
    await _saveSyncQueue(queue);
  }

  Future<void> clearSyncQueue() async {
    final file = _getFile('sync_queue');
    if (await file.exists()) {
      await file.delete();
    }
  }

  // ============================================================================
  // Last Sync Timestamp
  // ============================================================================

  Future<void> setLastSyncTime(DateTime time) async {
    await initialize();
    final file = _getFile('last_sync');
    await file.writeAsString(time.toIso8601String());
  }

  Future<DateTime?> getLastSyncTime() async {
    await initialize();
    final file = _getFile('last_sync');

    if (!await file.exists()) {
      return null;
    }

    try {
      final content = await file.readAsString();
      return DateTime.parse(content);
    } catch (e) {
      return null;
    }
  }

  // ============================================================================
  // Clear All Data
  // ============================================================================

  Future<void> clearAllData() async {
    await initialize();
    if (await _dataDir.exists()) {
      await _dataDir.delete(recursive: true);
      await _dataDir.create(recursive: true);
    }
  }
}

// ============================================================================
// Sync Queue Item Model
// ============================================================================

enum SyncAction { create, update, delete }
enum SyncEntityType { account, customer, vendor, invoice, bill, journalEntry, payment, creditNote, debitNote }

class SyncQueueItem {
  final String id;
  final SyncAction action;
  final SyncEntityType entityType;
  final String entityId;
  final Map<String, dynamic>? data;
  final DateTime createdAt;
  final int retryCount;

  SyncQueueItem({
    required this.id,
    required this.action,
    required this.entityType,
    required this.entityId,
    this.data,
    required this.createdAt,
    this.retryCount = 0,
  });

  factory SyncQueueItem.fromJson(Map<String, dynamic> json) {
    return SyncQueueItem(
      id: json['id'] as String,
      action: SyncAction.values.firstWhere(
        (e) => e.name == json['action'],
        orElse: () => SyncAction.create,
      ),
      entityType: SyncEntityType.values.firstWhere(
        (e) => e.name == json['entity_type'],
        orElse: () => SyncEntityType.account,
      ),
      entityId: json['entity_id'] as String,
      data: json['data'] as Map<String, dynamic>?,
      createdAt: DateTime.parse(json['created_at'] as String),
      retryCount: json['retry_count'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'action': action.name,
      'entity_type': entityType.name,
      'entity_id': entityId,
      'data': data,
      'created_at': createdAt.toIso8601String(),
      'retry_count': retryCount,
    };
  }

  SyncQueueItem copyWith({
    String? id,
    SyncAction? action,
    SyncEntityType? entityType,
    String? entityId,
    Map<String, dynamic>? data,
    DateTime? createdAt,
    int? retryCount,
  }) {
    return SyncQueueItem(
      id: id ?? this.id,
      action: action ?? this.action,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      data: data ?? this.data,
      createdAt: createdAt ?? this.createdAt,
      retryCount: retryCount ?? this.retryCount,
    );
  }
}

// ============================================================================
// Provider
// ============================================================================

final localStorageServiceProvider = Provider<LocalStorageService>((ref) {
  return LocalStorageService.instance;
});
