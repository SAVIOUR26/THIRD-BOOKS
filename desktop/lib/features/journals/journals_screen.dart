// ignore: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/data_service.dart';
import '../../core/services/api_client.dart';
import '../../core/models/journal_entry.dart';
import '../../core/models/account.dart';
import '../../core/models/recurring_journal.dart';
import '../../core/providers/recurring_journals_provider.dart';
import '../../core/widgets/attachment_widget.dart';
import '../../core/widgets/account_search_field.dart';

class JournalsScreen extends ConsumerStatefulWidget {
  const JournalsScreen({super.key});

  @override
  ConsumerState<JournalsScreen> createState() => _JournalsScreenState();
}

class _JournalsScreenState extends ConsumerState<JournalsScreen> {
  String _searchQuery = '';
  DateTimeRange? _dateRange;
  JournalEntryStatus? _selectedStatus;

  // Pagination — industry standard for high-volume accounting journals
  int _pageIndex = 0;
  static const int _pageSize = 50;

  // Reset to page 0 whenever a filter changes so results are visible immediately.
  void _applyFilter(VoidCallback fn) {
    setState(() {
      fn();
      _pageIndex = 0;
    });
  }

  List<JournalEntry> get _filteredEntries {
    final journalsState = ref.watch(journalsProvider);
    final filtered = journalsState.entries.where((entry) {
      final matchesSearch = _searchQuery.isEmpty ||
          entry.description.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          entry.entryNumber.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          (entry.reference?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false);
      final matchesStatus = _selectedStatus == null || entry.status == _selectedStatus;
      final matchesDate = _dateRange == null ||
          (entry.date.isAfter(_dateRange!.start.subtract(const Duration(days: 1))) &&
              entry.date.isBefore(_dateRange!.end.add(const Duration(days: 1))));
      return matchesSearch && matchesStatus && matchesDate;
    }).toList();

    // Newest first. Entries live in state.entries in whatever order they
    // were added, not by date — day-to-day entries happen to land roughly
    // chronological since they're created in real time, but a bulk action
    // (e.g. back-filling several months of depreciation in one go) appends
    // all of them to the end of the list at once. Without sorting here,
    // those brand-new entries land on the very last page instead of the
    // first — correct, but effectively invisible unless you know to click
    // all the way to the end.
    filtered.sort((a, b) => b.date.compareTo(a.date));
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final journalsState = ref.watch(journalsProvider);

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            const SizedBox(height: 24),
            _buildFilters(context),
            const SizedBox(height: 16),
            _buildSummaryCards(context),
            const SizedBox(height: 16),
            Expanded(
              child: journalsState.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : journalsState.entries.isEmpty
                      ? _buildEmptyState(context)
                      : _buildJournalTable(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.book_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'No journal entries yet',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create your first journal entry to start tracking transactions',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => _showNewJournalEntryDialog(context),
            icon: const Icon(Icons.add),
            label: const Text('New Journal Entry'),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Journal Entries',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Record and manage financial transactions',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () {
                ref.invalidate(journalsProvider);
                setState(() => _pageIndex = 0);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Journals refreshed'), duration: Duration(seconds: 1)),
                );
              },
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => _exportToCSV(context),
              icon: const Icon(Icons.file_download_outlined, size: 18),
              label: const Text('Export'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => _showRecurringManageDialog(context),
              icon: const Icon(Icons.repeat, size: 18),
              label: const Text('Recurring'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () => _showNewJournalEntryDialog(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Entry'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFilters(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Search entries...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => _applyFilter(() => _searchQuery = ''),
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            onChanged: (value) => _applyFilter(() => _searchQuery = value),
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: 180,
          child: DropdownButtonFormField<JournalEntryStatus?>(
            value: _selectedStatus,
            decoration: const InputDecoration(
              hintText: 'All Statuses',
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            items: [
              const DropdownMenuItem<JournalEntryStatus?>(
                value: null,
                child: Text('All Statuses'),
              ),
              ...JournalEntryStatus.values.map((status) => DropdownMenuItem(
                    value: status,
                    child: Text(_getStatusLabel(status)),
                  )),
            ],
            onChanged: (value) => _applyFilter(() => _selectedStatus = value),
          ),
        ),
        const SizedBox(width: 16),
        OutlinedButton.icon(
          onPressed: () async {
            final range = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 365)),
              initialDateRange: _dateRange,
            );
            if (range != null) {
              _applyFilter(() => _dateRange = range);
            }
          },
          icon: const Icon(Icons.calendar_today, size: 18),
          label: Text(_dateRange != null
              ? '${DateFormat('MMM d').format(_dateRange!.start)} - ${DateFormat('MMM d').format(_dateRange!.end)}'
              : 'Date Range'),
        ),
        if (_dateRange != null) ...[
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.clear, size: 18),
            onPressed: () => _applyFilter(() => _dateRange = null),
            tooltip: 'Clear date filter',
          ),
        ],
      ],
    );
  }

  Widget _buildSummaryCards(BuildContext context) {
    final journalsState = ref.watch(journalsProvider);
    final entries = journalsState.entries;

    final posted = entries.where((e) => e.status == JournalEntryStatus.posted).length;
    final draft = entries.where((e) => e.status == JournalEntryStatus.draft).length;
    final pending = entries.where((e) => e.status == JournalEntryStatus.pending).length;
    final totalDebit = entries.fold<double>(0, (sum, e) => sum + e.totalDebit);

    return Row(
      children: [
        _SummaryCard(
          icon: Icons.check_circle,
          iconColor: AppColors.income,
          label: 'Posted',
          value: posted.toString(),
        ),
        const SizedBox(width: 16),
        _SummaryCard(
          icon: Icons.edit_note,
          iconColor: AppColors.warning,
          label: 'Drafts',
          value: draft.toString(),
        ),
        const SizedBox(width: 16),
        _SummaryCard(
          icon: Icons.pending_actions,
          iconColor: AppColors.info,
          label: 'Pending',
          value: pending.toString(),
        ),
        const SizedBox(width: 16),
        _SummaryCard(
          icon: Icons.account_balance_wallet,
          iconColor: AppColors.primary,
          label: 'Total Volume',
          value: 'UGX ${_formatNumber(totalDebit)}',
        ),
      ],
    );
  }

  Widget _buildJournalTable(BuildContext context) {
    final allEntries = _filteredEntries;

    if (allEntries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No entries match your filters',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ),
      );
    }

    // Paginate — render only the current page so scrolling stays fast even
    // with thousands of journal entries (industry standard for ERP/accounting).
    final totalPages = ((allEntries.length - 1) ~/ _pageSize) + 1;
    final safePageIndex = _pageIndex.clamp(0, totalPages - 1);
    final entries = allEntries.skip(safePageIndex * _pageSize).take(_pageSize).toList();

    final firstItem = safePageIndex * _pageSize + 1;
    final lastItem = (safePageIndex * _pageSize + entries.length);

    return Column(
      children: [
        Expanded(
          child: Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              child: DataTable(
            columnSpacing: 24,
            horizontalMargin: 24,
            headingRowColor: MaterialStateProperty.all(
              Theme.of(context).colorScheme.surfaceVariant,
            ),
            columns: const [
              DataColumn(label: Text('Entry ID')),
              DataColumn(label: Text('Date')),
              DataColumn(label: Text('Description')),
              DataColumn(label: Text('Reference')),
              DataColumn(label: Text('Debit'), numeric: true),
              DataColumn(label: Text('Credit'), numeric: true),
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('Actions')),
            ],
            rows: entries.map((entry) {
              return DataRow(
                cells: [
                  DataCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(entry.entryNumber, style: const TextStyle(fontWeight: FontWeight.w500, fontFamily: 'monospace')),
                        if (entry.isReversed) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.orange.withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
                            child: Text('Reversed', style: TextStyle(fontSize: 10, color: Colors.orange.shade700, fontWeight: FontWeight.w600)),
                          ),
                        ],
                        if (entry.isReversal) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.blue.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
                            child: const Text('↩ Reversal', style: TextStyle(fontSize: 10, color: Colors.blue, fontWeight: FontWeight.w600)),
                          ),
                        ],
                        if (entry.recurringTemplateId != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.purple.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
                            child: const Text('🔁 Auto', style: TextStyle(fontSize: 10, color: Colors.purple, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ],
                    ),
                    onTap: () => _showEntryDetails(context, entry),
                  ),
                  DataCell(Text(DateFormat('MMM d, yyyy').format(entry.date))),
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 250),
                      child: Text(
                        entry.description,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    onTap: () => _showEntryDetails(context, entry),
                  ),
                  DataCell(Text(entry.reference ?? '-')),
                  DataCell(
                    Text(
                      'UGX ${_formatNumber(entry.totalDebit)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w500,
                        color: AppColors.debit,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  DataCell(
                    Text(
                      'UGX ${_formatNumber(entry.totalCredit)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w500,
                        color: AppColors.credit,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  DataCell(_buildStatusBadge(entry.status)),
                  DataCell(
                    SizedBox(
                      width: 208,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.visibility_outlined, size: 18),
                            onPressed: () => _showEntryDetails(context, entry),
                            tooltip: 'View',
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: entry.status != JournalEntryStatus.voided
                                ? () => _showEditEntryDialog(context, entry)
                                : null,
                            tooltip: 'Edit',
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () => _confirmDeleteEntry(context, entry),
                            tooltip: 'Delete',
                            color: AppColors.error,
                          ),
                          if (entry.status == JournalEntryStatus.draft ||
                              entry.status == JournalEntryStatus.pending)
                            IconButton(
                              icon: const Icon(Icons.check_circle_outline, size: 18),
                              onPressed: () => _postEntry(context, entry),
                              tooltip: 'Post',
                              color: AppColors.income,
                            ),
                          if (entry.status == JournalEntryStatus.posted && !entry.isReversed && !entry.isReversal)
                            IconButton(
                              icon: const Icon(Icons.undo, size: 18),
                              onPressed: () => _showReverseDialog(context, entry),
                              tooltip: 'Reverse',
                              color: Colors.orange.shade700,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }).toList(),
              ),
            ),
          ),
        ),
        ),
        // ── Pagination footer ────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          child: Row(
            children: [
              Text(
                'Showing $firstItem–$lastItem of ${allEntries.length} entries',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.first_page, size: 20),
                tooltip: 'First page',
                onPressed: safePageIndex > 0
                    ? () => setState(() => _pageIndex = 0)
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 20),
                tooltip: 'Previous page',
                onPressed: safePageIndex > 0
                    ? () => setState(() => _pageIndex = safePageIndex - 1)
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Page ${safePageIndex + 1} of $totalPages',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                tooltip: 'Next page',
                onPressed: safePageIndex < totalPages - 1
                    ? () => setState(() => _pageIndex = safePageIndex + 1)
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.last_page, size: 20),
                tooltip: 'Last page',
                onPressed: safePageIndex < totalPages - 1
                    ? () => setState(() => _pageIndex = totalPages - 1)
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBadge(JournalEntryStatus status) {
    Color color;
    switch (status) {
      case JournalEntryStatus.posted:
        color = AppColors.income;
        break;
      case JournalEntryStatus.draft:
        color = AppColors.warning;
        break;
      case JournalEntryStatus.pending:
        color = AppColors.info;
        break;
      case JournalEntryStatus.voided:
        color = AppColors.expense;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _getStatusLabel(status),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _getStatusLabel(JournalEntryStatus status) {
    switch (status) {
      case JournalEntryStatus.posted:
        return 'Posted';
      case JournalEntryStatus.draft:
        return 'Draft';
      case JournalEntryStatus.pending:
        return 'Pending';
      case JournalEntryStatus.voided:
        return 'Voided';
    }
  }

  String _formatNumber(double number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(2)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(0)}K';
    }
    return number.toStringAsFixed(0);
  }

  void _exportToCSV(BuildContext context) async {
    final journalsState = ref.read(journalsProvider);
    if (journalsState.entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No journal entries to export')),
      );
      return;
    }

    try {
      final buffer = StringBuffer();
      buffer.writeln('Entry Number,Date,Description,Reference,Total Debit,Total Credit,Status,Created By');

      for (final entry in journalsState.entries) {
        buffer.writeln(
          '${entry.entryNumber},'
          '${DateFormat('yyyy-MM-dd').format(entry.date)},'
          '"${entry.description.replaceAll('"', '""')}",'
          '"${entry.reference ?? ''}",'
          '${entry.totalDebit},'
          '${entry.totalCredit},'
          '${_getStatusLabel(entry.status)},'
          '"${entry.createdBy ?? ''}"',
        );
      }

      final bytes = const Utf8Encoder().convert(buffer.toString());
      final fileName = 'journal_entries_${DateFormat('yyyyMMdd').format(DateTime.now())}.csv';
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save CSV File',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (savePath != null) {
        final finalPath = savePath.endsWith('.csv') ? savePath : '\$savePath.csv';
        await File(finalPath).writeAsBytes(bytes);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported ${journalsState.entries.length} entries to CSV')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  void _postEntry(BuildContext context, JournalEntry entry) {
    if (!entry.isBalanced) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot post: Debits and credits must be equal'),
          backgroundColor: AppColors.expense,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Post Journal Entry'),
        content: Text('Are you sure you want to post entry ${entry.entryNumber}? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              ref.read(journalsProvider.notifier).postEntry(entry.id);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Journal entry posted (will sync when online)'),
                  backgroundColor: AppColors.income,
                ),
              );
            },
            child: const Text('Post Entry'),
          ),
        ],
      ),
    );
  }

  void _showNewJournalEntryDialog(BuildContext context) {
    final accountsState = ref.read(accountsProvider);
    final dateController = TextEditingController(
      text: DateFormat('MMM d, yyyy').format(DateTime.now()),
    );
    final referenceController = TextEditingController();
    final descriptionController = TextEditingController();
    DateTime selectedDate = DateTime.now();

    // Start with two empty lines
    final List<_JournalLineData> lines = [
      _JournalLineData(),
      _JournalLineData(),
    ];

    // Pre-generate the entry ID so attachments are stored immediately.
    final newEntryId = const Uuid().v4();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          double totalDebit = lines.fold(0, (sum, line) => sum + line.debit);
          double totalCredit = lines.fold(0, (sum, line) => sum + line.credit);
          bool isBalanced = (totalDebit - totalCredit).abs() < 0.01;

          return AlertDialog(
            title: const Text('New Journal Entry'),
            content: SizedBox(
              width: 750,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: dateController,
                            decoration: const InputDecoration(
                              labelText: 'Date',
                              suffixIcon: Icon(Icons.calendar_today, size: 18),
                            ),
                            readOnly: true,
                            onTap: () async {
                              final date = await showDatePicker(
                                context: context,
                                initialDate: selectedDate,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now().add(const Duration(days: 365)),
                              );
                              if (date != null) {
                                selectedDate = date;
                                dateController.text = DateFormat('MMM d, yyyy').format(date);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextFormField(
                            controller: referenceController,
                            decoration: const InputDecoration(labelText: 'Reference (Optional)'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: descriptionController,
                      decoration: const InputDecoration(labelText: 'Description *'),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Journal Lines', style: Theme.of(context).textTheme.titleMedium),
                        Row(
                          children: [
                            if (!isBalanced && totalDebit > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.expense.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'Unbalanced: ${NumberFormat('#,###').format((totalDebit - totalCredit).abs())}',
                                  style: const TextStyle(
                                    color: AppColors.expense,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            if (isBalanced && totalDebit > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.income.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.check, size: 14, color: AppColors.income),
                                    SizedBox(width: 4),
                                    Text(
                                      'Balanced',
                                      style: TextStyle(
                                        color: AppColors.income,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).dividerColor),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(flex: 3, child: Text('Account', style: TextStyle(fontWeight: FontWeight.w600))),
                              Expanded(flex: 2, child: Text('Debit', style: TextStyle(fontWeight: FontWeight.w600))),
                              Expanded(flex: 2, child: Text('Credit', style: TextStyle(fontWeight: FontWeight.w600))),
                              const SizedBox(width: 40),
                            ],
                          ),
                          const Divider(),
                          ...lines.asMap().entries.map((entry) {
                            final index = entry.key;
                            final line = entry.value;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: AccountSearchField(
                                      accounts: accountsState.accounts,
                                      value: line.accountId.isEmpty ? null : line.accountId,
                                      onChanged: (v) {
                                        setDialogState(() {
                                          line.accountId = v ?? '';
                                          final matched = accountsState.accounts
                                              .cast<Account?>()
                                              .firstWhere((a) => a?.id == v, orElse: () => null);
                                          if (matched != null) line.accountName = matched.name;
                                        });
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    flex: 2,
                                    child: TextFormField(
                                      initialValue: line.debit > 0 ? line.debit.toString() : '',
                                      decoration: const InputDecoration(
                                        hintText: '0.00',
                                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        isDense: true,
                                      ),
                                      keyboardType: TextInputType.number,
                                      onChanged: (v) {
                                        setDialogState(() {
                                          line.debit = double.tryParse(v) ?? 0;
                                          if (line.debit > 0) line.credit = 0;
                                        });
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    flex: 2,
                                    child: TextFormField(
                                      initialValue: line.credit > 0 ? line.credit.toString() : '',
                                      decoration: const InputDecoration(
                                        hintText: '0.00',
                                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        isDense: true,
                                      ),
                                      keyboardType: TextInputType.number,
                                      onChanged: (v) {
                                        setDialogState(() {
                                          line.credit = double.tryParse(v) ?? 0;
                                          if (line.credit > 0) line.debit = 0;
                                        });
                                      },
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 18),
                                    onPressed: lines.length > 2
                                        ? () {
                                            setDialogState(() {
                                              lines.removeAt(index);
                                            });
                                          }
                                        : null,
                                  ),
                                ],
                              ),
                            );
                          }),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: () {
                              setDialogState(() {
                                lines.add(_JournalLineData());
                              });
                            },
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Add Line'),
                          ),
                          const Divider(),
                          Row(
                            children: [
                              const Expanded(flex: 3, child: Text('Total', style: TextStyle(fontWeight: FontWeight.bold))),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  NumberFormat('#,###').format(totalDebit),
                                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.debit),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  NumberFormat('#,###').format(totalCredit),
                                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.credit),
                                ),
                              ),
                              const SizedBox(width: 40),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    AttachmentPanel(
                      attachableType: 'journal-entry',
                      localRecordId: newEntryId,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              OutlinedButton(
                onPressed: () {
                  if (descriptionController.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter a description')),
                    );
                    return;
                  }
                  if (lines.where((l) => l.accountId.isNotEmpty).length < 2) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please add at least 2 lines with accounts')),
                    );
                    return;
                  }
                  _saveEntry(
                    context: context,
                    entryId: newEntryId,
                    date: selectedDate,
                    description: descriptionController.text,
                    reference: referenceController.text.isEmpty ? null : referenceController.text,
                    lines: lines,
                    status: JournalEntryStatus.draft,
                  );
                  Navigator.pop(ctx);
                },
                child: const Text('Save as Draft'),
              ),
              FilledButton(
                onPressed: isBalanced && totalDebit > 0
                    ? () {
                        if (descriptionController.text.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please enter a description')),
                          );
                          return;
                        }
                        if (lines.where((l) => l.accountId.isNotEmpty).length < 2) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please add at least 2 lines with accounts')),
                          );
                          return;
                        }
                        _saveEntry(
                          context: context,
                          entryId: newEntryId,
                          date: selectedDate,
                          description: descriptionController.text,
                          reference: referenceController.text.isEmpty ? null : referenceController.text,
                          lines: lines,
                          status: JournalEntryStatus.posted,
                        );
                        Navigator.pop(ctx);
                      }
                    : null,
                child: const Text('Post Entry'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _saveEntry({
    required BuildContext context,
    required String entryId,
    required DateTime date,
    required String description,
    String? reference,
    required List<_JournalLineData> lines,
    required JournalEntryStatus status,
  }) {
    final validLines = lines.where((l) => l.accountId.isNotEmpty && (l.debit > 0 || l.credit > 0)).toList();

    final journalLines = validLines.map((l) {
      return JournalLine(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        journalEntryId: '',
        accountId: l.accountId,
        accountName: l.accountName,
        debit: l.debit,
        credit: l.credit,
      );
    }).toList();

    final entry = JournalEntry(
      id: entryId,
      entryNumber: 'JE-${DateFormat('yyyyMMdd').format(date)}-${DateTime.now().millisecondsSinceEpoch % 1000}',
      date: date,
      description: description,
      reference: reference,
      status: status,
      lines: journalLines,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    ref.read(journalsProvider.notifier).addEntry(entry);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(status == JournalEntryStatus.posted
            ? 'Journal entry posted (will sync when online)'
            : 'Journal entry saved as draft (will sync when online)'),
        backgroundColor: AppColors.income,
      ),
    );
  }

  void _showEditEntryDialog(BuildContext context, JournalEntry entry) {
    final accountsState = ref.read(accountsProvider);
    final dateCtrl = TextEditingController(text: DateFormat('MMM d, yyyy').format(entry.date));
    final refCtrl  = TextEditingController(text: entry.reference ?? '');
    final descCtrl = TextEditingController(text: entry.description);
    DateTime selectedDate = entry.date;

    final List<_JournalLineData> lines = entry.lines.map((l) {
      final ld = _JournalLineData();
      ld.accountId   = l.accountId;
      ld.accountName = l.accountName ?? '';
      ld.debit       = l.debit;
      ld.credit      = l.credit;
      return ld;
    }).toList();
    if (lines.length < 2) lines.add(_JournalLineData());

    // One TextEditingController per line — prevents initialValue reset on setDialogState.
    List<TextEditingController> debitCtrls = lines
        .map((l) => TextEditingController(text: l.debit  > 0 ? l.debit.toStringAsFixed(0)  : ''))
        .toList();
    List<TextEditingController> creditCtrls = lines
        .map((l) => TextEditingController(text: l.credit > 0 ? l.credit.toStringAsFixed(0) : ''))
        .toList();

    final isPosted = entry.status == JournalEntryStatus.posted;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          double totalDebit  = lines.fold(0, (s, l) => s + l.debit);
          double totalCredit = lines.fold(0, (s, l) => s + l.credit);
          bool isBalanced    = (totalDebit - totalCredit).abs() < 0.01;

          return AlertDialog(
            title: Row(children: [
              Flexible(child: Text('Edit: ${entry.entryNumber}')),
              if (isPosted) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.expense.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('POSTED — ledger will update',
                      style: TextStyle(fontSize: 11, color: AppColors.expense)),
                ),
              ],
            ]),
            content: SizedBox(
              width: 750,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: TextFormField(
                          controller: dateCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Date',
                            suffixIcon: Icon(Icons.calendar_today, size: 18),
                          ),
                          readOnly: true,
                          onTap: () async {
                            final d = await showDatePicker(
                              context: context,
                              initialDate: selectedDate,
                              firstDate: DateTime(2020),
                              lastDate: DateTime.now().add(const Duration(days: 365)),
                            );
                            if (d != null) {
                              setDialogState(() {
                                selectedDate = d;
                                dateCtrl.text = DateFormat('MMM d, yyyy').format(d);
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextFormField(
                          controller: refCtrl,
                          decoration: const InputDecoration(labelText: 'Reference (Optional)'),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: descCtrl,
                      decoration: const InputDecoration(labelText: 'Description *'),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Journal Lines', style: Theme.of(context).textTheme.titleMedium),
                        if (!isBalanced && totalDebit > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.expense.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Unbalanced: ${NumberFormat('#,###').format((totalDebit - totalCredit).abs())}',
                              style: const TextStyle(color: AppColors.expense, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        if (isBalanced && totalDebit > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.income.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Row(children: [
                              Icon(Icons.check, size: 14, color: AppColors.income),
                              SizedBox(width: 4),
                              Text('Balanced', style: TextStyle(color: AppColors.income, fontSize: 12, fontWeight: FontWeight.w600)),
                            ]),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).dividerColor),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(children: [
                        Row(children: const [
                          Expanded(flex: 3, child: Text('Account', style: TextStyle(fontWeight: FontWeight.w600))),
                          Expanded(flex: 2, child: Text('Debit',   style: TextStyle(fontWeight: FontWeight.w600))),
                          Expanded(flex: 2, child: Text('Credit',  style: TextStyle(fontWeight: FontWeight.w600))),
                          SizedBox(width: 40),
                        ]),
                        const Divider(),
                        ...List.generate(lines.length, (index) {
                          final line = lines[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(children: [
                              Expanded(
                                flex: 3,
                                child: AccountSearchField(
                                  accounts: accountsState.accounts,
                                  value: line.accountId.isEmpty ? null : line.accountId,
                                  onChanged: (v) {
                                    setDialogState(() {
                                      line.accountId = v ?? '';
                                      final matched = accountsState.accounts
                                          .cast<Account?>()
                                          .firstWhere((a) => a?.id == v, orElse: () => null);
                                      if (matched != null) line.accountName = matched.name;
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  controller: debitCtrls[index],
                                  decoration: const InputDecoration(
                                    hintText: '0.00',
                                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    isDense: true,
                                  ),
                                  keyboardType: TextInputType.number,
                                  onChanged: (v) {
                                    setDialogState(() {
                                      line.debit = double.tryParse(v) ?? 0;
                                      if (line.debit > 0) {
                                        line.credit = 0;
                                        creditCtrls[index].clear();
                                      }
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  controller: creditCtrls[index],
                                  decoration: const InputDecoration(
                                    hintText: '0.00',
                                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    isDense: true,
                                  ),
                                  keyboardType: TextInputType.number,
                                  onChanged: (v) {
                                    setDialogState(() {
                                      line.credit = double.tryParse(v) ?? 0;
                                      if (line.credit > 0) {
                                        line.debit = 0;
                                        debitCtrls[index].clear();
                                      }
                                    });
                                  },
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, size: 18),
                                onPressed: lines.length > 2
                                    ? () => setDialogState(() {
                                          debitCtrls[index].dispose();
                                          creditCtrls[index].dispose();
                                          lines.removeAt(index);
                                          debitCtrls.removeAt(index);
                                          creditCtrls.removeAt(index);
                                        })
                                    : null,
                              ),
                            ]),
                          );
                        }),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () => setDialogState(() {
                            lines.add(_JournalLineData());
                            debitCtrls.add(TextEditingController());
                            creditCtrls.add(TextEditingController());
                          }),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add Line'),
                        ),
                        const Divider(),
                        Row(children: [
                          const Expanded(flex: 3, child: Text('Total', style: TextStyle(fontWeight: FontWeight.bold))),
                          Expanded(flex: 2, child: Text(NumberFormat('#,###').format(totalDebit),  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.debit))),
                          Expanded(flex: 2, child: Text(NumberFormat('#,###').format(totalCredit), style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.credit))),
                          const SizedBox(width: 40),
                        ]),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: isBalanced && totalDebit > 0
                    ? () {
                        if (descCtrl.text.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please enter a description')),
                          );
                          return;
                        }
                        final validLines = lines
                            .where((l) => l.accountId.isNotEmpty && (l.debit > 0 || l.credit > 0))
                            .toList();
                        if (validLines.length < 2) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please add at least 2 lines with accounts')),
                          );
                          return;
                        }
                        final journalLines = validLines.asMap().entries.map((e) => JournalLine(
                          id: '${entry.id}-line-${e.key}-${DateTime.now().millisecondsSinceEpoch}',
                          journalEntryId: entry.id,
                          accountId: e.value.accountId,
                          accountName: e.value.accountName,
                          debit: e.value.debit,
                          credit: e.value.credit,
                        )).toList();
                        final updated = JournalEntry(
                          id: entry.id,
                          entryNumber: entry.entryNumber,
                          date: selectedDate,
                          description: descCtrl.text,
                          reference: refCtrl.text.isEmpty ? null : refCtrl.text,
                          status: entry.status,
                          lines: journalLines,
                          createdAt: entry.createdAt,
                          updatedAt: DateTime.now(),
                          createdBy: entry.createdBy,
                          notes: entry.notes,
                        );
                        ref.read(journalsProvider.notifier).updateEntry(updated);
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Entry ${entry.entryNumber} updated${isPosted ? ' — ledger recomputed' : ''}'),
                            backgroundColor: AppColors.income,
                          ),
                        );
                      }
                    : null,
                child: const Text('Save Changes'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _confirmDeleteEntry(BuildContext context, JournalEntry entry) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Journal Entry'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Delete ${entry.entryNumber}?'),
            if (entry.status == JournalEntryStatus.posted) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.expense.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(children: [
                  Icon(Icons.warning_amber_rounded, color: AppColors.expense, size: 18),
                  SizedBox(width: 8),
                  Flexible(child: Text(
                    'This entry is POSTED. Deleting it will remove it from the ledger and recompute all balances.',
                    style: TextStyle(fontSize: 12, color: AppColors.expense),
                  )),
                ]),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () {
              ref.read(journalsProvider.notifier).removeEntries([entry.id]);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${entry.entryNumber} deleted'),
                  backgroundColor: AppColors.error,
                ),
              );
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showReverseDialog(BuildContext context, JournalEntry entry) async {
    DateTime selectedDate = DateTime.now();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Reverse Journal Entry'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('This will create a new posted journal entry that exactly cancels out ${entry.entryNumber}.'),
              const SizedBox(height: 8),
              Text('The original entry will remain intact and be marked as Reversed.', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text('Reversal date: ', style: TextStyle(fontWeight: FontWeight.w600)),
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: ctx,
                        initialDate: selectedDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2030),
                      );
                      if (d != null) setS(() => selectedDate = d);
                    },
                    child: Text(DateFormat('d MMM yyyy').format(selectedDate)),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create Reversal'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) {
      ref.read(journalsProvider.notifier).reverseEntry(entry.id, selectedDate);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Reversal entry REV-${entry.entryNumber} created and posted.'),
          backgroundColor: Colors.orange.shade700,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _showRecurringManageDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => _RecurringManageDialog(
        accountsState: ref.read(accountsProvider),
      ),
    );
  }

  void _showEntryDetails(BuildContext context, JournalEntry entry) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Journal Entry: ${entry.entryNumber}'),
            _buildStatusBadge(entry.status),
          ],
        ),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailRow('Date', DateFormat('MMMM d, yyyy').format(entry.date)),
                _DetailRow('Description', entry.description),
                _DetailRow('Reference', entry.reference ?? '-'),
                _DetailRow('Created By', entry.createdBy ?? 'System'),
                _DetailRow('Created At', DateFormat('MMM d, yyyy HH:mm').format(entry.createdAt)),
                if (entry.notes != null && entry.notes!.isNotEmpty)
                  _DetailRow('Notes', entry.notes!),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text('Lines', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    if (entry.isBalanced)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.income.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check, size: 14, color: AppColors.income),
                            SizedBox(width: 4),
                            Text(
                              'Balanced',
                              style: TextStyle(
                                color: AppColors.income,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: DataTable(
                    columnSpacing: 16,
                    columns: const [
                      DataColumn(label: Text('Account')),
                      DataColumn(label: Text('Description')),
                      DataColumn(label: Text('Debit'), numeric: true),
                      DataColumn(label: Text('Credit'), numeric: true),
                    ],
                    rows: [
                      ...entry.lines.map((line) {
                        return DataRow(cells: [
                          DataCell(Text(
                            line.accountCode != null
                                ? '${line.accountCode}  ${line.accountName ?? line.accountId}'
                                : (line.accountName ?? line.accountId),
                          )),
                          DataCell(Text(
                            line.description ?? '',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                            overflow: TextOverflow.ellipsis,
                          )),
                          DataCell(Text(
                            line.debit > 0 ? 'UGX ${NumberFormat('#,###').format(line.debit)}' : '-',
                            style: const TextStyle(color: AppColors.debit, fontFamily: 'monospace'),
                          )),
                          DataCell(Text(
                            line.credit > 0 ? 'UGX ${NumberFormat('#,###').format(line.credit)}' : '-',
                            style: const TextStyle(color: AppColors.credit, fontFamily: 'monospace'),
                          )),
                        ]);
                      }),
                      DataRow(
                        color: MaterialStateProperty.all(
                          Theme.of(context).colorScheme.surfaceVariant,
                        ),
                        cells: [
                          const DataCell(Text('Total', style: TextStyle(fontWeight: FontWeight.bold))),
                          const DataCell(SizedBox.shrink()),
                          DataCell(Text(
                            'UGX ${NumberFormat('#,###').format(entry.totalDebit)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: AppColors.debit,
                              fontFamily: 'monospace',
                            ),
                          )),
                          DataCell(Text(
                            'UGX ${NumberFormat('#,###').format(entry.totalCredit)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: AppColors.credit,
                              fontFamily: 'monospace',
                            ),
                          )),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                AttachmentPanel(
                  attachableType: 'journal-entry',
                  localRecordId: entry.id,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          if (entry.status == JournalEntryStatus.draft)
            FilledButton(
              onPressed: entry.isBalanced
                  ? () {
                      ref.read(journalsProvider.notifier).postEntry(entry.id);
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Text('Journal entry posted (will sync when online)'),
                          backgroundColor: AppColors.income,
                        ),
                      );
                    }
                  : null,
              child: const Text('Post Entry'),
            ),
        ],
      ),
    );
  }
}

class _JournalLineData {
  String accountId = '';
  String accountName = '';
  double debit = 0;
  double credit = 0;
}

class _SummaryCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  const _SummaryCard({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });


  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

// ── Recurring Journal Management Dialog ───────────────────────────────────────

class _RecurringManageDialog extends ConsumerStatefulWidget {
  final AccountsState accountsState;

  const _RecurringManageDialog({required this.accountsState});

  @override
  ConsumerState<_RecurringManageDialog> createState() => _RecurringManageDialogState();
}

class _RecurringManageDialogState extends ConsumerState<_RecurringManageDialog> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recurringJournalsProvider);

    return Dialog(
      child: SizedBox(
        width: 700,
        height: 560,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
              child: Row(
                children: [
                  const Icon(Icons.repeat, size: 22),
                  const SizedBox(width: 10),
                  Text('Recurring Journals', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: () => _showNewTemplateDialog(context),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New Template'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            const Divider(height: 20),
            Expanded(
              child: state.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : state.templates.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.repeat_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
                              const SizedBox(height: 12),
                              Text('No recurring templates yet', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
                              const SizedBox(height: 16),
                              OutlinedButton.icon(
                                onPressed: () => _showNewTemplateDialog(context),
                                icon: const Icon(Icons.add, size: 16),
                                label: const Text('Create first template'),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemCount: state.templates.length,
                          itemBuilder: (ctx, i) {
                            final t = state.templates[i];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              leading: Container(
                                width: 40, height: 40,
                                decoration: BoxDecoration(
                                  color: t.isActive ? Colors.purple.withOpacity(0.12) : Colors.grey.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(Icons.repeat, size: 20, color: t.isActive ? Colors.purple : Colors.grey),
                              ),
                              title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                '${t.description}  •  Next: ${DateFormat('d MMM yyyy').format(t.nextRunDate)}',
                                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: _freqColor(t.frequency).withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      _freqLabel(t.frequency),
                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _freqColor(t.frequency)),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Switch(
                                    value: t.isActive,
                                    onChanged: (_) => ref.read(recurringJournalsProvider.notifier).toggleActive(t.id),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                                    onPressed: () => _confirmDelete(context, t),
                                    tooltip: 'Delete template',
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Color _freqColor(RecurringFrequency f) {
    switch (f) {
      case RecurringFrequency.daily:     return Colors.red;
      case RecurringFrequency.weekly:    return Colors.orange;
      case RecurringFrequency.monthly:   return Colors.blue;
      case RecurringFrequency.quarterly: return Colors.teal;
      case RecurringFrequency.annually:  return Colors.purple;
    }
  }

  String _freqLabel(RecurringFrequency f) {
    switch (f) {
      case RecurringFrequency.daily:     return 'Daily';
      case RecurringFrequency.weekly:    return 'Weekly';
      case RecurringFrequency.monthly:   return 'Monthly';
      case RecurringFrequency.quarterly: return 'Quarterly';
      case RecurringFrequency.annually:  return 'Annually';
    }
  }

  void _confirmDelete(BuildContext context, RecurringJournal t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Template'),
        content: Text('Delete "${t.name}"? Already-posted entries are not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) ref.read(recurringJournalsProvider.notifier).deleteTemplate(t.id);
  }

  void _showNewTemplateDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => _NewRecurringTemplateDialog(accountsState: widget.accountsState),
    );
  }
}

// ── New Recurring Template Dialog ─────────────────────────────────────────────

class _NewRecurringTemplateDialog extends ConsumerStatefulWidget {
  final AccountsState accountsState;
  const _NewRecurringTemplateDialog({required this.accountsState});

  @override
  ConsumerState<_NewRecurringTemplateDialog> createState() => _NewRecurringTemplateDialogState();
}

class _NewRecurringTemplateDialogState extends ConsumerState<_NewRecurringTemplateDialog> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _refCtrl  = TextEditingController();
  RecurringFrequency _frequency = RecurringFrequency.monthly;
  DateTime _startDate = DateTime.now();
  DateTime? _endDate;

  // Lines
  final List<Map<String, dynamic>> _lines = [];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _refCtrl.dispose();
    super.dispose();
  }

  void _addLine() {
    setState(() {
      _lines.add({'accountId': '', 'accountName': '', 'accountCode': '', 'debit': 0.0, 'credit': 0.0});
    });
  }

  double get _totalDebit  => _lines.fold(0.0, (s, l) => s + (l['debit'] as double));
  double get _totalCredit => _lines.fold(0.0, (s, l) => s + (l['credit'] as double));
  bool   get _isBalanced  => (_totalDebit - _totalCredit).abs() < 0.01;

  void _save() {
    if (_nameCtrl.text.trim().isEmpty) return;
    if (_lines.length < 2 || !_isBalanced) return;

    const uuid = Uuid();
    final now = DateTime.now();
    final template = RecurringJournal(
      id: uuid.v4(),
      name: _nameCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      frequency: _frequency,
      startDate: _startDate,
      endDate: _endDate,
      nextRunDate: _startDate,
      isActive: true,
      reference: _refCtrl.text.trim().isEmpty ? null : _refCtrl.text.trim(),
      lines: _lines.map((l) => RecurringJournalLine(
        accountId:   l['accountId'] as String,
        accountName: l['accountName'] as String,
        accountCode: l['accountCode'] as String,
        debit:       l['debit'] as double,
        credit:      l['credit'] as double,
      )).toList(),
      createdAt: now,
      updatedAt: now,
    );

    ref.read(recurringJournalsProvider.notifier).addTemplate(template);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 680,
        height: 620,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
              child: Row(
                children: [
                  Text('New Recurring Template', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            const Divider(height: 20),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(child: TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Template Name *', hintText: 'e.g. Monthly Rent'))),
                      const SizedBox(width: 16),
                      Expanded(child: TextField(controller: _refCtrl, decoration: const InputDecoration(labelText: 'Reference', hintText: 'Optional'))),
                    ]),
                    const SizedBox(height: 12),
                    TextField(controller: _descCtrl, decoration: const InputDecoration(labelText: 'Description', hintText: 'Will appear on each auto-posted entry')),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<RecurringFrequency>(
                          value: _frequency,
                          decoration: const InputDecoration(labelText: 'Frequency'),
                          items: RecurringFrequency.values.map((f) => DropdownMenuItem(
                            value: f,
                            child: Text(f.name[0].toUpperCase() + f.name.substring(1)),
                          )).toList(),
                          onChanged: (v) { if (v != null) setState(() => _frequency = v); },
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: InkWell(
                          onTap: () async {
                            final d = await showDatePicker(
                              context: context, initialDate: _startDate,
                              firstDate: DateTime(2020), lastDate: DateTime(2035),
                            );
                            if (d != null) setState(() => _startDate = d);
                          },
                          child: InputDecorator(
                            decoration: const InputDecoration(labelText: 'Start Date'),
                            child: Text(DateFormat('d MMM yyyy').format(_startDate)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: InkWell(
                          onTap: () async {
                            final d = await showDatePicker(
                              context: context,
                              initialDate: _endDate ?? _startDate.add(const Duration(days: 365)),
                              firstDate: DateTime(2020), lastDate: DateTime(2040),
                            );
                            setState(() => _endDate = d);
                          },
                          child: InputDecorator(
                            decoration: const InputDecoration(labelText: 'End Date (optional)'),
                            child: Text(_endDate != null ? DateFormat('d MMM yyyy').format(_endDate!) : 'No end'),
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Text('Journal Lines', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                        const Spacer(),
                        OutlinedButton.icon(
                          onPressed: _addLine,
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add Line'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_lines.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text('Add at least two lines (debit and credit must balance).',
                            style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 13)),
                      ),
                    ..._lines.asMap().entries.map((entry) {
                      final i = entry.key;
                      final line = entry.value;
                      final debitCtrl  = TextEditingController(text: line['debit'] == 0.0 ? '' : line['debit'].toString());
                      final creditCtrl = TextEditingController(text: line['credit'] == 0.0 ? '' : line['credit'].toString());
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: AccountSearchField(
                                accounts: widget.accountsState.accounts,
                                value: (line['accountId'] as String).isEmpty ? null : line['accountId'] as String,
                                onChanged: (id) => setState(() {
                                  final acct = widget.accountsState.accounts.cast<Account?>().firstWhere((a) => a?.id == id, orElse: () => null);
                                  _lines[i]['accountId']   = id ?? '';
                                  _lines[i]['accountName'] = acct?.name ?? '';
                                  _lines[i]['accountCode'] = acct?.code ?? '';
                                }),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 110,
                              child: TextField(
                                controller: debitCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(labelText: 'Debit', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                                onChanged: (v) => setState(() => _lines[i]['debit'] = double.tryParse(v) ?? 0.0),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 110,
                              child: TextField(
                                controller: creditCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(labelText: 'Credit', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                                onChanged: (v) => setState(() => _lines[i]['credit'] = double.tryParse(v) ?? 0.0),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline, size: 18, color: Colors.red),
                              onPressed: () => setState(() => _lines.removeAt(i)),
                            ),
                          ],
                        ),
                      );
                    }),
                    if (_lines.length >= 2)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text('Debit: ${_totalDebit.toStringAsFixed(0)}   Credit: ${_totalCredit.toStringAsFixed(0)}   '),
                            Text(
                              _isBalanced ? '✓ Balanced' : '✗ Not balanced',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: _isBalanced ? Colors.green : Colors.red,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: (_nameCtrl.text.trim().isNotEmpty && _lines.length >= 2 && _isBalanced) ? _save : null,
                    child: const Text('Save Template'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

