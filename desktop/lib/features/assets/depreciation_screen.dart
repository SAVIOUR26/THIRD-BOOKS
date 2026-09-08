import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_theme.dart';
import '../../core/providers/asset_drafts_provider.dart';
import '../../core/providers/depreciation_schedules_provider.dart';
import '../../core/services/data_service.dart';
import '../../core/models/journal_entry.dart';

/// Asset Depreciation Screen
///
/// Features:
/// - Percentage-based depreciation (Declining Balance method)
/// - Period selection: Monthly or Yearly
/// - Auto-generate depreciation journal entries
/// - View depreciation schedules and history
class DepreciationScreen extends ConsumerStatefulWidget {
  const DepreciationScreen({super.key});

  @override
  ConsumerState<DepreciationScreen> createState() => _DepreciationScreenState();
}

class _DepreciationScreenState extends ConsumerState<DepreciationScreen> {
  final _currencyFormat = NumberFormat.currency(symbol: 'UGX ', decimalDigits: 0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Asset Depreciation'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.calculate),
            onPressed: _showDepreciationCalculator,
            tooltip: 'Depreciation Calculator',
          ),
          IconButton(
            icon: const Icon(Icons.schedule),
            onPressed: _generateDepreciationEntries,
            tooltip: 'Generate Entries',
          ),
        ],
      ),
      body: Column(
        children: [
          // Summary
          _buildSummarySection(),

          // Depreciation Schedules List
          Expanded(
            child: _buildSchedulesList(),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.tonalIcon(
            onPressed: _setupDepreciationForAllAssets,
            icon: const Icon(Icons.playlist_add),
            label: const Text('Setup All Assets'),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            onPressed: _showSetupDepreciationDialog,
            icon: const Icon(Icons.add),
            label: const Text('Setup Depreciation'),
          ),
        ],
      ),
    );
  }

  Widget _buildSummarySection() {
    final schedules = ref.watch(depreciationSchedulesProvider);
    final fmt = NumberFormat('#,###');
    final active = schedules.where((s) => s.isActive).length;
    final totalDep = schedules.fold<double>(
        0, (s, d) => s + d.accumulatedDepreciation);
    final now = DateTime.now();
    final thisMonthDep = schedules
        .where((s) =>
            s.isActive &&
            s.period == 'monthly' &&
            s.lastRunDate != null &&
            s.lastRunDate!.year == now.year &&
            s.lastRunDate!.month == now.month)
        .fold<double>(0, (s, d) => s + d.nextDepreciation);
    final due = schedules.where((s) => s.isActive && s.isDue).length;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border:
            Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildSummaryCard(
              'Active Schedules', '$active', Icons.schedule, AppColors.primary),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _buildSummaryCard(
              'Total Depreciated',
              'UGX ${fmt.format(totalDep)}',
              Icons.trending_down,
              AppColors.warning,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _buildSummaryCard(
              'This Month',
              'UGX ${fmt.format(thisMonthDep)}',
              Icons.calendar_today,
              AppColors.info,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _buildSummaryCard(
              'Due for Entry', '$due', Icons.pending_actions, AppColors.error),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildSchedulesList() {
    final schedules = ref.watch(depreciationSchedulesProvider);
    final fmt = NumberFormat('#,###');
    final dateFmt = DateFormat('dd MMM yyyy');

    if (schedules.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.schedule_outlined,
                size: 64,
                color: Theme.of(context)
                    .colorScheme
                    .outline
                    .withOpacity(0.3)),
            const SizedBox(height: 16),
            Text('No depreciation schedules yet',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.outline)),
            const SizedBox(height: 8),
            const Text('Confirm assets first, then set up depreciation'),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _setupDepreciationForAllAssets,
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Setup All Assets'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _showSetupDepreciationDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('Setup Depreciation'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      itemCount: schedules.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final s = schedules[i];
        final pct = s.percentageDepreciated;
        final isDue = s.isDue && s.isActive;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _categoryIcon(s.assetCategory),
                      size: 20,
                      color: s.isActive ? AppColors.primary : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(s.assetName,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                    ),
                    if (isDue)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text('Due',
                            style: TextStyle(
                                color: AppColors.warning,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                      ),
                    const SizedBox(width: 8),
                    Switch(
                      value: s.isActive,
                      onChanged: (_) => ref
                          .read(depreciationSchedulesProvider.notifier)
                          .toggleActive(s.id),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Progress bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (pct / 100).clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceVariant,
                    color: pct >= 80 ? AppColors.error : AppColors.primary,
                  ),
                ),
                const SizedBox(height: 8),
                // Key figures
                Row(
                  children: [
                    _DepField('Original',
                        'UGX ${fmt.format(s.assetValue)}'),
                    _DepField('Current Value',
                        'UGX ${fmt.format(s.currentValue)}'),
                    _DepField('Depreciated',
                        '${pct.toStringAsFixed(1)}%'),
                    _DepField(
                      'Next ${s.period == 'monthly' ? 'month' : 'year'}',
                      'UGX ${fmt.format(s.nextDepreciation)}',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      '${s.method == 'declining_balance' ? 'Declining Balance' : 'Straight Line'}'
                      '  •  ${s.rate}% / ${s.period}'
                      '  •  Started ${dateFmt.format(s.startDate)}',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.outline),
                    ),
                    const Spacer(),
                    if (s.isActive)
                      TextButton.icon(
                        onPressed: isDue
                            ? () => _postDepreciationJournalEntries([s])
                            : null,
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('Run Now'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          size: 18, color: AppColors.error),
                      tooltip: 'Remove schedule',
                      onPressed: () => ref
                          .read(depreciationSchedulesProvider.notifier)
                          .remove(s.id),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  IconData _categoryIcon(String cat) {
    switch (cat) {
      case 'Vehicle': return Icons.directions_car;
      case 'Equipment': return Icons.build;
      case 'Furniture': return Icons.chair;
      case 'Electronics': return Icons.devices;
      case 'Building': return Icons.business;
      case 'Machinery': return Icons.precision_manufacturing;
      default: return Icons.inventory_2;
    }
  }

  // Default method/rate by category now lives in depreciation_schedules_provider.dart
  // as defaultDepreciationFor() — shared with the automatic on-confirm
  // schedule creation so both paths always agree.

  /// Bulk-creates a depreciation schedule (using category defaults, monthly
  /// period, starting from each asset's purchase date) for every confirmed
  /// asset that doesn't already have one. This only creates the schedules —
  /// it does not post any journal entries; "Generate Entries" / "Run Now"
  /// still does that separately, so the accountant reviews before posting.
  void _setupDepreciationForAllAssets() {
    final confirmedAssets =
        ref.read(assetDraftsProvider).where((a) => a.isConfirmed).toList();
    final scheduledIds =
        ref.read(depreciationSchedulesProvider).map((s) => s.assetDraftId).toSet();
    final pending = confirmedAssets
        .where((a) => !scheduledIds.contains(a.id) && a.category != 'Land')
        .toList();
    final skippedLand = confirmedAssets
        .any((a) => a.category == 'Land' && !scheduledIds.contains(a.id));

    if (pending.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(skippedLand
              ? 'Every depreciable confirmed asset already has a schedule. Land is not depreciated.'
              : 'Every confirmed asset already has a depreciation schedule.'),
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Setup Depreciation for ${pending.length} Assets'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Creates a monthly schedule for each asset below using standard '
                'rates by category. Nothing is posted to the ledger yet — review '
                'or adjust any schedule afterwards, then use "Generate Entries" '
                'when ready.',
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: pending.length,
                  itemBuilder: (context, i) {
                    final a = pending[i];
                    final d = defaultDepreciationFor(a.category);
                    final rateLabel = d.rate == d.rate.roundToDouble()
                        ? d.rate.toStringAsFixed(0)
                        : d.rate.toStringAsFixed(2);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                              child: Text(a.assetName,
                                  overflow: TextOverflow.ellipsis)),
                          Text(
                            '${d.method == 'straight_line' ? 'SL' : 'DB'} $rateLabel%',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              if (skippedLand)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Land assets are excluded — land is not depreciated.',
                    style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final notifier = ref.read(depreciationSchedulesProvider.notifier);
              final now = DateTime.now();
              for (final a in pending) {
                final d = defaultDepreciationFor(a.category);
                await notifier.add(DepreciationSchedule(
                  id: const Uuid().v4(),
                  assetDraftId: a.id,
                  assetName: a.assetName,
                  assetCategory: a.category,
                  assetValue: a.amount,
                  currentValue: a.amount,
                  method: d.method,
                  rate: d.rate,
                  period: 'monthly',
                  startDate: a.date,
                  createdAt: now,
                ));
              }
              if (mounted) {
                Navigator.pop(dialogContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        '${pending.length} depreciation schedules created. '
                        'Use "Generate Entries" to post them to the ledger.'),
                    backgroundColor: AppColors.success,
                  ),
                );
              }
            },
            child: const Text('Create Schedules'),
          ),
        ],
      ),
    );
  }

  void _showSetupDepreciationDialog() {
    final confirmedAssets =
        ref.read(assetDraftsProvider).where((a) => a.isConfirmed).toList();

    if (confirmedAssets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No confirmed assets yet. Go to Assets, add a bill with an asset category, then confirm it.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }

    final formKey = GlobalKey<FormState>();
    final rateController = TextEditingController(text: '20');
    DateTime startDate = DateTime.now();
    String selectedMethod = 'declining_balance';
    String selectedPeriod = 'yearly';
    AssetDraft? selectedAsset;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setS) {
          final rate = double.tryParse(rateController.text) ?? 20.0;
          final assetVal = selectedAsset?.amount ?? 0.0;
          final exY1 = selectedMethod == 'declining_balance'
              ? assetVal * rate / 100
              : assetVal * rate / 100;
          final exY2 = selectedMethod == 'declining_balance'
              ? (assetVal - exY1) * rate / 100
              : assetVal * rate / 100;
          final fmt = NumberFormat('#,###');

          return AlertDialog(
            title: const Text('Setup Asset Depreciation'),
            content: SizedBox(
              width: 580,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Asset picker
                      DropdownButtonFormField<AssetDraft>(
                        value: selectedAsset,
                        decoration: const InputDecoration(
                          labelText: 'Select Asset *',
                          prefixIcon: Icon(Icons.inventory_2),
                        ),
                        items: confirmedAssets
                            .map((a) => DropdownMenuItem(
                                  value: a,
                                  child: Text(
                                    '${a.assetName}  (${a.currency} ${NumberFormat('#,###').format(a.amount)})',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ))
                            .toList(),
                        onChanged: (v) => setS(() => selectedAsset = v),
                        validator: (v) =>
                            v == null ? 'Please select an asset' : null,
                      ),
                      const SizedBox(height: 16),

                      DropdownButtonFormField<String>(
                        value: selectedMethod,
                        decoration: const InputDecoration(
                          labelText: 'Depreciation Method',
                          prefixIcon: Icon(Icons.calculate),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'declining_balance',
                            child: Text('Declining Balance (Reducing Balance)'),
                          ),
                          DropdownMenuItem(
                            value: 'straight_line',
                            child: Text('Straight Line'),
                          ),
                        ],
                        onChanged: (v) => setS(() => selectedMethod = v!),
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        controller: rateController,
                        decoration: const InputDecoration(
                          labelText: 'Annual Depreciation Rate *',
                          suffixText: '%',
                          prefixIcon: Icon(Icons.percent),
                          hintText: '20',
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setS(() {}),
                        validator: (v) {
                          final r = double.tryParse(v ?? '');
                          if (r == null || r <= 0 || r > 100) {
                            return 'Enter a percentage between 1 and 100';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      DropdownButtonFormField<String>(
                        value: selectedPeriod,
                        decoration: const InputDecoration(
                          labelText: 'Run Period',
                          prefixIcon: Icon(Icons.date_range),
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: 'monthly', child: Text('Monthly')),
                          DropdownMenuItem(
                              value: 'yearly', child: Text('Yearly')),
                        ],
                        onChanged: (v) => setS(() => selectedPeriod = v!),
                      ),
                      const SizedBox(height: 16),

                      InkWell(
                        onTap: () async {
                          final d = await showDatePicker(
                            context: dialogContext,
                            initialDate: startDate,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (d != null) setS(() => startDate = d);
                        },
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Start Date *',
                            prefixIcon: Icon(Icons.calendar_today),
                          ),
                          child: Text(DateFormat('dd MMM yyyy').format(startDate)),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Live preview box
                      if (selectedAsset != null)
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.info.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: AppColors.info.withOpacity(0.3)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                const Icon(Icons.info_outline,
                                    color: AppColors.info, size: 18),
                                const SizedBox(width: 6),
                                Text(
                                  'Projection for ${selectedAsset!.assetName}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13),
                                ),
                              ]),
                              const SizedBox(height: 10),
                              _buildPreviewRow('Asset Value',
                                  'UGX ${fmt.format(assetVal)}'),
                              _buildPreviewRow('Method',
                                  selectedMethod == 'declining_balance'
                                      ? 'Declining Balance'
                                      : 'Straight Line'),
                              _buildPreviewRow(
                                  'Rate', '$rate% per year'),
                              const Divider(height: 16),
                              _buildPreviewRow(
                                  'Year 1 Depreciation',
                                  'UGX ${fmt.format(exY1)}'
                                  '  →  UGX ${fmt.format(assetVal - exY1)} remaining'),
                              _buildPreviewRow(
                                  'Year 2 Depreciation',
                                  'UGX ${fmt.format(exY2)}'
                                  '  →  UGX ${fmt.format(assetVal - exY1 - exY2)} remaining'),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () async {
                  if (!formKey.currentState!.validate()) return;
                  if (selectedAsset == null) return;

                  final schedule = DepreciationSchedule(
                    id: const Uuid().v4(),
                    assetDraftId: selectedAsset!.id,
                    assetName: selectedAsset!.assetName,
                    assetCategory: selectedAsset!.category,
                    assetValue: selectedAsset!.amount,
                    currentValue: selectedAsset!.amount,
                    method: selectedMethod,
                    rate: double.parse(rateController.text),
                    period: selectedPeriod,
                    startDate: startDate,
                    createdAt: DateTime.now(),
                  );

                  await ref
                      .read(depreciationSchedulesProvider.notifier)
                      .add(schedule);

                  if (mounted) {
                    Navigator.pop(dialogContext);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            'Depreciation schedule created for ${selectedAsset!.assetName}'),
                        backgroundColor: AppColors.success,
                      ),
                    );
                  }
                },
                child: const Text('Create Schedule'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPreviewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  void _showDepreciationCalculator() {
    final formKey = GlobalKey<FormState>();
    final assetValueController = TextEditingController();
    final rateController = TextEditingController(text: '20');
    final yearsController = TextEditingController(text: '5');
    String selectedPeriod = 'yearly';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          // Calculate depreciation schedule
          List<Map<String, dynamic>> schedule = [];
          if (assetValueController.text.isNotEmpty &&
              rateController.text.isNotEmpty &&
              yearsController.text.isNotEmpty) {
            final assetValue = double.tryParse(assetValueController.text.replaceAll(',', '')) ?? 0;
            final rate = double.tryParse(rateController.text) ?? 0;
            final years = int.tryParse(yearsController.text) ?? 0;

            if (assetValue > 0 && rate > 0 && years > 0) {
              double remainingValue = assetValue;
              for (var i = 1; i <= years; i++) {
                final depreciation = remainingValue * (rate / 100);
                remainingValue -= depreciation;
                schedule.add({
                  'year': i,
                  'depreciation': depreciation,
                  'remaining': remainingValue,
                });
              }
            }
          }

          return AlertDialog(
            title: const Text('Depreciation Calculator'),
            content: SizedBox(
              width: 700,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: assetValueController,
                              decoration: const InputDecoration(
                                labelText: 'Asset Value',
                                prefixText: 'UGX ',
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextFormField(
                              controller: rateController,
                              decoration: const InputDecoration(
                                labelText: 'Rate',
                                suffixText: '%',
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextFormField(
                              controller: yearsController,
                              decoration: const InputDecoration(
                                labelText: 'Years',
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      if (schedule.isNotEmpty) ...[
                        const Text(
                          'Depreciation Schedule',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(8),
                                    topRight: Radius.circular(8),
                                  ),
                                ),
                                child: Row(
                                  children: const [
                                    Expanded(child: Text('Year', style: TextStyle(fontWeight: FontWeight.bold))),
                                    Expanded(child: Text('Depreciation', style: TextStyle(fontWeight: FontWeight.bold))),
                                    Expanded(child: Text('Book Value', style: TextStyle(fontWeight: FontWeight.bold))),
                                  ],
                                ),
                              ),
                              ...schedule.map((row) => Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      border: Border(
                                        top: BorderSide(color: Colors.grey.shade300),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(child: Text('Year ${row['year']}')),
                                        Expanded(child: Text(_currencyFormat.format(row['depreciation']))),
                                        Expanded(child: Text(_currencyFormat.format(row['remaining']))),
                                      ],
                                    ),
                                  )),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _generateDepreciationEntries() {
    final schedules = ref.read(depreciationSchedulesProvider);
    final due = schedules.where((s) => s.isActive && s.isDue).toList();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Generate Depreciation Entries'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This will post journal entries for ${ due.isEmpty ? "0 (none due)" : "${due.length} asset(s) due" }:'),
            const SizedBox(height: 12),
            if (due.isEmpty)
              const Text('No schedules are currently due. Check back later or set up a new schedule.',
                  style: TextStyle(color: Colors.grey))
            else
              ...due.map((s) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• ${s.assetName}  →  ${_currencyFormat.format(s.nextDepreciation)}',
                  style: const TextStyle(fontSize: 13),
                ),
              )),
            const SizedBox(height: 12),
            const Text('Each entry: DR Depreciation/Amortization Expense / CR Accumulated Depreciation/Amortization',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: due.isEmpty
                ? null
                : () {
                    Navigator.pop(context);
                    _postDepreciationJournalEntries(due);
                  },
            child: const Text('Generate'),
          ),
        ],
      ),
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

  /// True if [expenseAccountCode] already has posted debit activity within
  /// [periodStart]..[periodEnd] — i.e. depreciation/amortization for this
  /// exact month already exists in the ledger, most likely from an earlier
  /// manual journal entry predating this per-asset schedule system. Used to
  /// stop "Run" from ever posting a duplicate on top of it.
  bool _periodAlreadyRecorded(
      List<JournalEntry> allEntries, String expenseAccountCode, DateTime periodStart, DateTime periodEnd) {
    for (final e in allEntries) {
      if (e.status != JournalEntryStatus.posted) continue;
      if (e.date.isBefore(periodStart) || e.date.isAfter(periodEnd)) continue;
      for (final line in e.lines) {
        if (line.accountCode == expenseAccountCode && line.debit > 0) return true;
      }
    }
    return false;
  }

  Future<void> _postDepreciationJournalEntries(List<DepreciationSchedule> due) async {
    final journalsNotifier = ref.read(journalsProvider.notifier);
    final schedNotifier   = ref.read(depreciationSchedulesProvider.notifier);

    // Wait for the real journal history to finish loading before reading it
    // for the duplicate-period check below, or building the batch to post.
    // JournalsNotifier starts empty and loads a possibly 20MB+ file in the
    // background; reading it too early here previously meant both the
    // duplicate-check silently saw nothing AND the batch save that follows
    // overwrote the entire real journals file with just this run's new
    // entries — reproduced live as "reports blank, bank balance disappeared"
    // right after running depreciation as the first action after opening.
    await journalsNotifier.ready;
    if (!mounted) return;
    final allEntries = ref.read(journalsProvider).entries;
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
        // top of it. Skip this period without touching currentValue, but
        // still advance past it so the schedule doesn't stay stuck asking
        // for the same already-covered month forever.
        if (_periodAlreadyRecorded(allEntries, expenseCode, periodDate, periodEnd)) {
          skipped.add('${schedule.assetName} — $periodLabel');
          current = current.applyDepreciation(periodEnd, 0);
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

      // Persist the fully-caught-up schedule.
      schedNotifier.updateSchedule(current);
    }

    // One single save for every entry collected across every asset/period.
    journalsNotifier.addEntries(newEntries);

    final message = StringBuffer(
        '$posted depreciation ${posted == 1 ? "entry" : "entries"} posted to Chart of Accounts');
    if (skipped.isNotEmpty) {
      final shown = skipped.take(4).join(', ');
      final more = skipped.length > 4 ? ' and ${skipped.length - 4} more' : '';
      message.write('. Skipped ${skipped.length} period(s) already recorded elsewhere: $shown$more.');
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message.toString()),
        backgroundColor: skipped.isEmpty ? AppColors.success : AppColors.warning,
        duration: const Duration(seconds: 6),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small helper: one stat column inside the depreciation schedule card
// ---------------------------------------------------------------------------
class _DepField extends StatelessWidget {
  final String label;
  final String value;
  const _DepField(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}
