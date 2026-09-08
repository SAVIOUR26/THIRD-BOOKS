// Data Service for MagicBet Accounting Desktop App
// Offline-First Architecture with Local Storage and Sync Queue
// © 2026 Magic Bet Ltd. All rights reserved.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart' hide Column;

import 'api_client.dart';
import 'auth_service.dart';
import 'local_storage_service.dart';
import 'sync_service.dart';
import 'theme_service.dart';
import '../models/models.dart';
import '../database/app_database.dart' hide Account, Customer, Vendor, Invoice, Bill, JournalEntry, JournalLine;
import '../providers/asset_drafts_provider.dart';
import '../providers/local_outlet_csv_uploads_provider.dart';

// Global local storage instance
final _localStorage = LocalStorageService.instance;
const _uuid = Uuid();

// Database provider
final databaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabase();
});

// ============================================================================
// MagicBet Ltd — Professional Chart of Accounts
// IFRS-compliant, Uganda gaming industry standard
// Structured per URA, GRB (Gaming Regulatory Board) and IFRS requirements
// ============================================================================

List<Account> _magicBetDefaultAccounts() {
  final now = DateTime.now();

  Account a(
    String code,
    String name,
    AccountType type,
    AccountSubType subType, {
    String? desc,
    bool system = false,
  }) =>
      Account(
        id: 'acct-$code',
        code: code,
        name: name,
        description: desc,
        type: type,
        subType: subType,
        isSystemAccount: system,
        createdAt: now,
        updatedAt: now,
      );

  // Chart of Accounts — sourced from client's COA.xlsx (codes 100–177)
  // Organised into: Cash/Bank · Revenue · Direct Costs · Expenses ·
  //                 Liabilities · Assets · Equity
  return [
    // ════════════════════════════════════════════════════════════════════════
    // CASH & BANK  (100–102)
    // ════════════════════════════════════════════════════════════════════════
    a('100', 'Petty Cash',                              AccountType.asset,     AccountSubType.cash,         system: true),
    a('101', 'ABSA UGX Account',                        AccountType.asset,     AccountSubType.bank,         system: true),
    a('102', 'MTN Momopay',                             AccountType.asset,     AccountSubType.bank,         system: true),

    // ════════════════════════════════════════════════════════════════════════
    // REVENUE  (103–107)
    // ════════════════════════════════════════════════════════════════════════
    a('103', 'Stakes',                                  AccountType.revenue,   AccountSubType.salesRevenue, system: true,
      desc: 'Gross cash wagered by customers across all 72 outlets'),
    a('104', 'Other Revenue',                           AccountType.revenue,   AccountSubType.otherIncome),
    a('106', 'Interest Income',                         AccountType.revenue,   AccountSubType.otherIncome),
    a('185', 'Outlet Premise Income',                   AccountType.revenue,   AccountSubType.otherIncome),
    a('107', 'Payouts',                                 AccountType.revenue,   AccountSubType.salesRevenue, system: true,
      desc: 'Contra-revenue: total winnings paid out to customers (debit balance reduces Stakes)'),

    // ════════════════════════════════════════════════════════════════════════
    // DIRECT COSTS  (108, 130)
    // ════════════════════════════════════════════════════════════════════════
    a('108', 'Gaming Tax',                              AccountType.expense,   AccountSubType.costOfGoodsSold, system: true,
      desc: '15% GGR gaming tax remitted monthly to Uganda Revenue Authority (URA)'),
    a('130', 'Gambling License Fee',                    AccountType.expense,   AccountSubType.costOfGoodsSold,
      desc: 'GRB gaming operating licence fee'),

    // ════════════════════════════════════════════════════════════════════════
    // MARKETING EXPENSES  (109–113, 128)
    // ════════════════════════════════════════════════════════════════════════
    a('109', 'Offline Advertising',                     AccountType.expense,   AccountSubType.marketingExpense),
    a('110', 'Online Advertising',                      AccountType.expense,   AccountSubType.marketingExpense),
    a('111', 'Campaigns',                               AccountType.expense,   AccountSubType.marketingExpense),
    a('112', 'PR & Social Marketing',                   AccountType.expense,   AccountSubType.marketingExpense),
    a('113', 'Sponsorships',                            AccountType.expense,   AccountSubType.marketingExpense),
    a('128', 'Corporate Social Responsibility',         AccountType.expense,   AccountSubType.marketingExpense),

    // ════════════════════════════════════════════════════════════════════════
    // STAFF COSTS  (114–115, 117–118, 131–135)
    // ════════════════════════════════════════════════════════════════════════
    a('114', 'Team Budget',                             AccountType.expense,   AccountSubType.staffCosts),
    a('115', 'Entertainment',                           AccountType.expense,   AccountSubType.staffCosts),
    a('117', 'WC Insurance',                            AccountType.expense,   AccountSubType.staffCosts,
      desc: "Worker's Compensation insurance for employees"),
    a('118', 'Medical Insurance',                       AccountType.expense,   AccountSubType.staffCosts),
    a('131', 'Other Employment Benefits',               AccountType.expense,   AccountSubType.staffCosts),
    a('132', 'Salaries',                                AccountType.expense,   AccountSubType.staffCosts,   system: true),
    a('133', 'Meals & Refreshments',                    AccountType.expense,   AccountSubType.staffCosts),
    a('134', 'Employee Learning and Development',       AccountType.expense,   AccountSubType.staffCosts),
    a('135', 'Employer Contribution NSSF',              AccountType.expense,   AccountSubType.staffCosts,
      desc: '10% employer NSSF contribution per NSSF Act Uganda'),

    // ════════════════════════════════════════════════════════════════════════
    // PROFESSIONAL FEES  (120–123)
    // ════════════════════════════════════════════════════════════════════════
    a('120', 'Audit Fees',                              AccountType.expense,   AccountSubType.professionalFees),
    a('121', 'Legal Expenses',                          AccountType.expense,   AccountSubType.professionalFees),
    a('122', 'Accounting and Tax',                      AccountType.expense,   AccountSubType.professionalFees),
    a('123', 'Consulting Expense',                      AccountType.expense,   AccountSubType.professionalFees),
    a('163', "Directors' Fees",                         AccountType.expense,   AccountSubType.professionalFees),

    // ════════════════════════════════════════════════════════════════════════
    // OPERATING EXPENSES  (105, 116, 119, 124–127, 129, 136–137, 141–145, 160–162)
    // ════════════════════════════════════════════════════════════════════════
    a('105', 'Responsible Gambling Expenses',           AccountType.expense,   AccountSubType.operatingExpense,
      desc: 'GRB-required responsible gambling programme costs'),
    a('116', 'All Risk Insurance',                      AccountType.expense,   AccountSubType.operatingExpense),
    a('119', 'Interest Expense',                        AccountType.expense,   AccountSubType.otherExpense),
    a('124', 'Share Capital Expenses',                  AccountType.expense,   AccountSubType.otherExpense),
    a('125', 'Office Expenses',                         AccountType.expense,   AccountSubType.operatingExpense),
    a('126', 'Internet and Other Services',             AccountType.expense,   AccountSubType.operatingExpense),
    a('127', 'Utilities',                               AccountType.expense,   AccountSubType.operatingExpense),
    a('129', 'Rent',                                    AccountType.expense,   AccountSubType.operatingExpense),
    a('136', 'Travel Expenses',                         AccountType.expense,   AccountSubType.operatingExpense),
    a('137', 'Bank Charges',                            AccountType.expense,   AccountSubType.operatingExpense),
    a('141', 'Tax Penalties',                           AccountType.expense,   AccountSubType.operatingExpense),
    a('142', 'Income Tax Expense',                      AccountType.expense,   AccountSubType.otherExpense),
    a('143', 'Depreciation',                            AccountType.expense,   AccountSubType.operatingExpense),
    a('180', 'Amortization Expense',                    AccountType.expense,   AccountSubType.operatingExpense,
      desc: 'Periodic amortization charge on intangible assets (IAS 38)'),
    a('144', 'Withholding Tax',                         AccountType.expense,   AccountSubType.operatingExpense),
    a('145', 'VAT Expense',                             AccountType.expense,   AccountSubType.operatingExpense),
    a('160', 'Technical Services Fee',                  AccountType.expense,   AccountSubType.operatingExpense),
    a('161', 'Platform Services Fee',                   AccountType.expense,   AccountSubType.operatingExpense),
    a('162', 'Support Services Fee',                    AccountType.expense,   AccountSubType.operatingExpense),
    a('178', 'Outlet Commission Expense',               AccountType.expense,   AccountSubType.operatingExpense, system: true,
      desc: '40% of adjusted weekly GGR owed to outlet location owners (carry-forward basis)'),
    a('181', 'Premise Fees',                            AccountType.expense,   AccountSubType.operatingExpense),
    a('182', 'License Application Fees',                AccountType.expense,   AccountSubType.operatingExpense),
    a('183', 'Repairs & Maintenance',                   AccountType.expense,   AccountSubType.operatingExpense),
    a('184', 'Domain Purchase & Hosting',               AccountType.expense,   AccountSubType.operatingExpense),

    // ════════════════════════════════════════════════════════════════════════
    // BANK REVALUATIONS & CURRENCY  (138–140)
    // ════════════════════════════════════════════════════════════════════════
    a('138', 'Bank Revaluations',                       AccountType.expense,   AccountSubType.bankRevaluation,
      desc: 'FX revaluation adjustments on foreign currency bank balances'),
    a('139', 'Unrealised Currency Gains',               AccountType.revenue,   AccountSubType.otherIncome),
    a('140', 'Realised Currency Gains',                 AccountType.revenue,   AccountSubType.otherIncome),

    // ════════════════════════════════════════════════════════════════════════
    // CURRENT LIABILITIES  (146–150, 164–170)
    // ════════════════════════════════════════════════════════════════════════
    a('146', 'Withholding Tax Payable — Suppliers',     AccountType.liability, AccountSubType.currentLiability),
    a('147', 'Gaming Tax Payable',                      AccountType.liability, AccountSubType.currentLiability, system: true,
      desc: '15% GGR gaming tax accrued, payable to URA'),
    a('148', 'PAYE Tax Payable',                        AccountType.liability, AccountSubType.currentLiability,
      desc: 'Pay As You Earn deducted from employees payable to URA'),
    a('149', 'NSSF Payable',                            AccountType.liability, AccountSubType.currentLiability,
      desc: 'Employee + employer NSSF contributions payable'),
    a('164', 'Accounts Payable',                        AccountType.liability, AccountSubType.accountsPayable, system: true),
    a('165', 'Wages Payable',                           AccountType.liability, AccountSubType.currentLiability),
    a('166', 'Accruals',                                AccountType.liability, AccountSubType.currentLiability),

    a('168', 'Employee Tax Payable',                    AccountType.liability, AccountSubType.currentLiability),
    a('169', 'Income Tax Payable',                      AccountType.liability, AccountSubType.currentLiability),
    a('170', 'Suspense',                                AccountType.liability, AccountSubType.currentLiability),
    a('171', 'Rounding',                                AccountType.expense,   AccountSubType.otherExpense),

    // ════════════════════════════════════════════════════════════════════════
    // NON-CURRENT LIABILITY  (172)
    // ════════════════════════════════════════════════════════════════════════
    a('172', 'Loan',                                    AccountType.liability, AccountSubType.longTermLiability),

    // ════════════════════════════════════════════════════════════════════════
    // ASSETS — RECEIVABLES, PREPAYMENTS & DEPOSITS  (150–153, 173)
    // ════════════════════════════════════════════════════════════════════════
    a('150', 'Accounts Receivable',                     AccountType.asset,     AccountSubType.accountsReceivable, system: true),
    a('151', 'Deposits — Rent',                         AccountType.asset,     AccountSubType.otherAsset,
      desc: 'Refundable rent deposits held at outlet premises'),
    a('152', 'Prepayments',                             AccountType.asset,     AccountSubType.otherCurrentAsset),
    a('153', 'Accrued Income',                          AccountType.asset,     AccountSubType.otherCurrentAsset),
    a('173', 'Share Capital Receivable',                AccountType.asset,     AccountSubType.otherCurrentAsset),
    a('174', 'UAP Umbrella Fund',                       AccountType.asset,     AccountSubType.otherCurrentAsset,
      desc: 'UAP insurance umbrella savings fund — current asset, not an operational bank account'),
    a('167', 'Bank Guarantee',                          AccountType.asset,     AccountSubType.otherCurrentAsset,
      desc: 'Security deposit held by bank on behalf of the company (e.g. GRB / landlord guarantee)'),

    // ════════════════════════════════════════════════════════════════════════
    // FIXED ASSETS  (154–159)
    // ════════════════════════════════════════════════════════════════════════
    a('154', 'Office Equipment',                        AccountType.asset,     AccountSubType.fixedAsset),
    a('155', 'Less Accum. Depreciation — Office Equipment',   AccountType.asset, AccountSubType.fixedAsset,
      desc: 'Contra-asset: accumulated depreciation on office equipment'),
    a('156', 'Computer Hardware Equipment',             AccountType.asset,     AccountSubType.fixedAsset),
    a('157', 'Less Accum. Depreciation — Computer Equipment', AccountType.asset, AccountSubType.fixedAsset,
      desc: 'Contra-asset: accumulated depreciation on computer hardware'),
    a('158', 'Office Furniture & Fittings',             AccountType.asset,     AccountSubType.fixedAsset),
    a('159', 'Less Accum. Depreciation — Office Furniture',   AccountType.asset, AccountSubType.fixedAsset,
      desc: 'Contra-asset: accumulated depreciation on furniture & fittings'),

    // ════════════════════════════════════════════════════════════════════════
    // INTANGIBLE ASSETS (IAS 38)  (1700–1820)
    // ════════════════════════════════════════════════════════════════════════
    a('1700', 'Intangible Assets',                      AccountType.asset,     AccountSubType.intangibleAsset,
      desc: 'IAS 38 – intangible assets (finite & indefinite life)'),
    a('1710', 'Software & Licenses',                    AccountType.asset,     AccountSubType.intangibleAsset,
      desc: 'Purchased software and perpetual licenses (IAS 38)'),
    a('1720', 'Patents & Trademarks',                   AccountType.asset,     AccountSubType.intangibleAsset,
      desc: 'Registered patents, trademarks and similar IP (IAS 38)'),
    a('1730', 'Goodwill',                               AccountType.asset,     AccountSubType.intangibleAsset,
      desc: 'Goodwill arising from business combinations (IFRS 3)'),
    a('1800', 'Accumulated Amortization',               AccountType.asset,     AccountSubType.intangibleAsset,
      desc: 'Contra-asset: total amortization charged on intangibles'),
    a('1810', 'Accumulated Amortization - Software',    AccountType.asset,     AccountSubType.intangibleAsset,
      desc: 'Contra-asset: amortization on software & licenses'),
    a('1820', 'Accumulated Amortization - Patents',     AccountType.asset,     AccountSubType.intangibleAsset,
      desc: 'Contra-asset: amortization on patents & trademarks'),

    // ════════════════════════════════════════════════════════════════════════
    // EQUITY  (175–177)
    // ════════════════════════════════════════════════════════════════════════
    a('175', 'Retained Earnings',                       AccountType.equity,    AccountSubType.retainedEarnings, system: true),
    a('176', 'Dividends Paid',                          AccountType.equity,    AccountSubType.ownersEquity),
    a('177', 'Share Capital',                           AccountType.equity,    AccountSubType.ownersEquity, system: true),
  ];
}

// ============================================================================
// Dashboard Service - Computed from real database data
// ============================================================================

class DashboardData {
  final double totalRevenue;
  final double totalExpenses;
  final double netIncome;
  final double outstandingInvoices;
  final int invoiceCount;
  final double revenueChange;
  final double expenseChange;
  final double incomeChange;
  final double cashIn;
  final double cashOut;
  final double netCash;
  final List<Map<String, double>> revenueData;
  final List<Map<String, double>> expenseData;
  final List<Map<String, dynamic>> receivableAging;
  final List<Map<String, dynamic>> recentTransactions;

  DashboardData({
    required this.totalRevenue,
    required this.totalExpenses,
    required this.netIncome,
    required this.outstandingInvoices,
    required this.invoiceCount,
    required this.revenueChange,
    required this.expenseChange,
    required this.incomeChange,
    required this.cashIn,
    required this.cashOut,
    required this.netCash,
    required this.revenueData,
    required this.expenseData,
    required this.receivableAging,
    required this.recentTransactions,
  });

  factory DashboardData.fromJson(Map<String, dynamic> json) {
    return DashboardData(
      totalRevenue: (json['total_revenue'] as num?)?.toDouble() ?? 0.0,
      totalExpenses: (json['total_expenses'] as num?)?.toDouble() ?? 0.0,
      netIncome: (json['net_income'] as num?)?.toDouble() ?? 0.0,
      outstandingInvoices: (json['outstanding_invoices'] as num?)?.toDouble() ?? 0.0,
      invoiceCount: json['invoice_count'] as int? ?? 0,
      revenueChange: (json['revenue_change'] as num?)?.toDouble() ?? 0.0,
      expenseChange: (json['expense_change'] as num?)?.toDouble() ?? 0.0,
      incomeChange: (json['income_change'] as num?)?.toDouble() ?? 0.0,
      cashIn: (json['cash_in'] as num?)?.toDouble() ?? 0.0,
      cashOut: (json['cash_out'] as num?)?.toDouble() ?? 0.0,
      netCash: (json['net_cash'] as num?)?.toDouble() ?? 0.0,
      revenueData: ((json['revenue_data'] as List<dynamic>?) ?? [])
          .map((e) => {'month': (e['month'] as num).toDouble(), 'value': (e['value'] as num).toDouble()})
          .toList(),
      expenseData: ((json['expense_data'] as List<dynamic>?) ?? [])
          .map((e) => {'month': (e['month'] as num).toDouble(), 'value': (e['value'] as num).toDouble()})
          .toList(),
      receivableAging: ((json['receivable_aging'] as List<dynamic>?) ?? [])
          .map((e) => e as Map<String, dynamic>)
          .toList(),
      recentTransactions: ((json['recent_transactions'] as List<dynamic>?) ?? [])
          .map((e) => e as Map<String, dynamic>)
          .toList(),
    );
  }

  factory DashboardData.empty() {
    return DashboardData(
      totalRevenue: 0,
      totalExpenses: 0,
      netIncome: 0,
      outstandingInvoices: 0,
      invoiceCount: 0,
      revenueChange: 0,
      expenseChange: 0,
      incomeChange: 0,
      cashIn: 0,
      cashOut: 0,
      netCash: 0,
      revenueData: [],
      expenseData: [],
      receivableAging: [],
      recentTransactions: [],
    );
  }
}

/// Dashboard data computed from real outlet revenue data in the database
final dashboardDataProvider = FutureProvider<DashboardData>((ref) async {
  final db = ref.read(databaseProvider);

  try {
    final allRevenues = await db.getAllOutletRevenues();
    final outlets = await db.getAllOutlets();

    if (allRevenues.isEmpty) {
      return DashboardData.empty();
    }

    // Run carry-forward commission engine per outlet to get accurate Net Revenue.
    // This is the real money MagicBet has available after paying 40% to outlet owners.
    double totalCashIn = 0;
    double totalCashOut = 0;   // raw payouts (Total Out column)
    double totalGGR = 0;       // Gross Gaming Revenue = Cash In - Cash Out
    double totalOutletExpense = 0;  // 40% commission (carry-forward adjusted)
    double totalNetRevenue = 0;    // what MagicBet actually keeps

    final revenuesByOutlet = <String, List<OutletRevenue>>{};
    for (final rev in allRevenues) {
      revenuesByOutlet.putIfAbsent(rev.outletId, () => []).add(rev);
      totalCashIn += rev.amount;
      totalCashOut += rev.commissionAmount;
      totalGGR += rev.netAmount;
    }

    // Monthly GGR and Net Revenue for charts
    final Map<int, double> monthlyGGR = {};
    final Map<int, double> monthlyNet = {};

    // Per-outlet net for top-outlets panel
    final Map<String, double> outletNet = {};

    for (final outlet in outlets) {
      final revs = revenuesByOutlet[outlet.id] ?? [];
      final weeks = _computeWeeksForOutlet(outlet, revs);
      final outletNetTotal = weeks.fold(0.0, (s, w) => s + w.netRevenue);
      final outletExpTotal = weeks.fold(0.0, (s, w) => s + w.outletExpense);
      totalOutletExpense += outletExpTotal;
      totalNetRevenue += outletNetTotal;
      outletNet[outlet.id] = outletNetTotal;

      // Monthly aggregation from weekly data
      for (final w in weeks) {
        final mo = w.weekStart.month;
        monthlyGGR[mo] = (monthlyGGR[mo] ?? 0) + w.rawGGR;
        monthlyNet[mo] = (monthlyNet[mo] ?? 0) + w.netRevenue;
      }
    }

    // Recent transactions (last 10 entries, sorted DESC)
    final sortedRevenues = List<OutletRevenue>.from(allRevenues)
      ..sort((a, b) => b.date.compareTo(a.date));

    final recentTx = <Map<String, dynamic>>[];
    for (var i = 0; i < sortedRevenues.length && i < 10; i++) {
      final rev = sortedRevenues[i];
      final outlet = outlets.where((o) => o.id == rev.outletId).firstOrNull;
      recentTx.add({
        'title': outlet?.name ?? 'Outlet',
        'subtitle': DateFormat('MMM d, yyyy').format(rev.date),
        'amount': rev.netAmount,
        'isIncome': rev.netAmount >= 0,
        'icon': 'payments',
      });
    }

    // Chart data: GGR line (light) and Net line (bold)
    final revenueData = monthlyGGR.entries
        .map((e) => {'month': e.key.toDouble(), 'value': e.value})
        .toList()
      ..sort((a, b) => a['month']!.compareTo(b['month']!));

    final expenseData = monthlyNet.entries
        .map((e) => {'month': e.key.toDouble(), 'value': e.value})
        .toList()
      ..sort((a, b) => a['month']!.compareTo(b['month']!));

    // Top outlets by net revenue for the panel
    final sortedByNet = outletNet.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topNet = sortedByNet.take(5).toList();
    final maxNet = topNet.isNotEmpty ? topNet.first.value.abs().clamp(1.0, double.infinity) : 1.0;

    final receivableAging = topNet.map((e) {
      final outlet = outlets.where((o) => o.id == e.key).firstOrNull;
      return {
        'label': outlet?.name ?? 'Unknown',
        'amount': e.value,
        'percentage': e.value / maxNet,
      };
    }).toList();

    return DashboardData(
      totalRevenue: totalGGR,
      totalExpenses: totalOutletExpense, // actual 40% commission expense
      netIncome: totalNetRevenue,        // real money MagicBet keeps
      outstandingInvoices: 0,
      invoiceCount: outlets.where((o) => o.isActive).length,
      revenueChange: 0,
      expenseChange: 0,
      incomeChange: 0,
      cashIn: totalCashIn,
      cashOut: totalCashOut,
      netCash: totalNetRevenue,
      revenueData: revenueData,
      expenseData: expenseData,
      receivableAging: receivableAging,
      recentTransactions: recentTx,
    );
  } catch (e) {
    debugPrint('Error computing dashboard data: $e');
    return DashboardData.empty();
  }
});

// ============================================================================
// Accounts Service - OFFLINE-FIRST with MagicBet defaults
// ============================================================================

class AccountsState {
  final List<Account> accounts;
  final bool isLoading;
  final String? error;

  AccountsState({
    this.accounts = const [],
    this.isLoading = false,
    this.error,
  });

  AccountsState copyWith({
    List<Account>? accounts,
    bool? isLoading,
    String? error,
  }) {
    return AccountsState(
      accounts: accounts ?? this.accounts,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class AccountsNotifier extends StateNotifier<AccountsState> {
  final ApiClient _apiClient;
  final Ref _ref;

  AccountsNotifier(this._apiClient, this._ref) : super(AccountsState()) {
    _initializeData();
  }

  Future<void> _initializeData() async {
    state = state.copyWith(isLoading: true);

    // Load from local storage (offline-first)
    try {
      final localAccounts = await _localStorage.loadAccounts();
      if (localAccounts.isNotEmpty) {
        // Detect old 4-digit IFRS codes (1000+) — migrate to client's COA.xlsx codes
        final needsMigration = localAccounts.every(
          (a) => (int.tryParse(a.code) ?? 0) >= 1000,
        );
        if (!needsMigration) {
          // Backfill any accounts added to the default CoA in newer app versions.
          final defaults = _magicBetDefaultAccounts();
          final existingCodes = localAccounts.map((a) => a.code).toSet();
          final missing = defaults.where((d) => !existingCodes.contains(d.code)).toList();
          if (missing.isNotEmpty) {
            debugPrint('Backfilling ${missing.length} new default accounts...');
            final merged = [...localAccounts, ...missing];
            await _localStorage.saveAccounts(merged);
            state = state.copyWith(accounts: merged, isLoading: false);
            await _repairJournalAccountIds(merged);
          } else {
            state = state.copyWith(accounts: localAccounts, isLoading: false);
            await _repairJournalAccountIds(localAccounts);
          }
          debugPrint('Loaded ${localAccounts.length + missing.length} accounts from local storage');
          return;
        }
        debugPrint('Old 4-digit IFRS codes detected — migrating to client CoA...');
      }
    } catch (e) {
      debugPrint('Error loading accounts from local storage: $e');
    }

    // Seed client's Chart of Accounts (COA.xlsx, codes 100–177)
    final defaults = _magicBetDefaultAccounts();
    try {
      await _localStorage.saveAccounts(defaults);
      debugPrint('Seeded ${defaults.length} accounts from client CoA.');
    } catch (e) {
      debugPrint('Warning: could not persist default accounts: $e');
    }
    state = state.copyWith(accounts: defaults, isLoading: false);
    await _repairJournalAccountIds(defaults);
    debugPrint('Chart of Accounts ready: ${defaults.length} accounts.');
  }

  Future<void> loadAccounts() async {
    // Reload from local storage
    try {
      final localAccounts = await _localStorage.loadAccounts();
      state = state.copyWith(accounts: localAccounts, isLoading: false);
    } catch (e) {
      debugPrint('Error loading accounts: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  /// Scan all journal entries and fix any lines whose accountId no longer
  /// matches a known account (e.g. after a purgeDemoData wipe replaced
  /// timestamp-based custom account IDs with the hardcoded 'acct-NNN' IDs).
  ///
  /// Strategy: match by accountCode first (most reliable), then by
  /// accountName (case-insensitive fallback).  Only persists if at least
  /// one line was repaired.
  Future<void> _repairJournalAccountIds(List<Account> accounts) async {
    try {
      final knownIds = accounts.map((a) => a.id).toSet();
      // If journals reference only known IDs there is nothing to do.
      final journals = await _localStorage.loadJournalEntries();
      final needsRepair = journals.any((je) =>
          je.lines.any((l) => !knownIds.contains(l.accountId)));
      if (!needsRepair) return;

      final byCode = <String, String>{for (final a in accounts) a.code: a.id};
      final byName = <String, String>{
        for (final a in accounts) a.name.toLowerCase(): a.id
      };

      int repairCount = 0;
      final repairedJournals = journals.map((je) {
        final repairedLines = je.lines.map((line) {
          if (knownIds.contains(line.accountId)) return line;
          final newId = (line.accountCode != null
                  ? byCode[line.accountCode]
                  : null) ??
              (line.accountName != null
                  ? byName[line.accountName!.toLowerCase()]
                  : null);
          if (newId == null) return line; // cannot resolve — leave as-is
          repairCount++;
          return line.copyWith(accountId: newId);
        }).toList();
        return je.copyWith(lines: repairedLines);
      }).toList();

      if (repairCount > 0) {
        await _localStorage.saveJournalEntries(repairedJournals);
        debugPrint('Repaired $repairCount journal line account references.');
      }
    } catch (e) {
      debugPrint('Warning: journal account-ID repair failed: $e');
    }
  }

  void addAccount(Account account) {
    final updatedAccounts = [...state.accounts, account];
    state = state.copyWith(accounts: updatedAccounts);

    _localStorage.saveAccounts(updatedAccounts);

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.create,
      entityType: SyncEntityType.account,
      entityId: account.id,
      data: account.toJson(),
    );
  }

  void updateAccount(Account account) {
    final updatedAccounts = state.accounts.map((a) {
      return a.id == account.id ? account : a;
    }).toList();
    state = state.copyWith(accounts: updatedAccounts);

    _localStorage.saveAccounts(updatedAccounts);

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.update,
      entityType: SyncEntityType.account,
      entityId: account.id,
      data: account.toJson(),
    );
  }

  /// Recompute every account's balance from the full set of posted journal
  /// entries so the Chart of Accounts reflects local JEs immediately —
  /// before the next server sync.
  ///
  /// Debit-normal accounts (assets, expenses): balance = Σdebits − Σcredits
  /// Credit-normal accounts (liabilities, equity, income): balance = Σcredits − Σdebits
  void recomputeBalancesFromJournals(List<JournalEntry> allEntries) {
    // Accumulate net movement per account ID from posted entries only.
    final totals = <String, double>{};
    for (final entry in allEntries) {
      if (entry.status != JournalEntryStatus.posted) continue;
      for (final line in entry.lines) {
        totals[line.accountId] = (totals[line.accountId] ?? 0.0);
        final acct = state.accounts.cast<Account?>().firstWhere(
          (a) => a?.id == line.accountId,
          orElse: () => null,
        );
        if (acct == null) continue;
        // Debit accounts: debits increase balance, credits decrease it.
        // Credit accounts: credits increase balance, debits decrease it.
        final isDebit = acct.type == AccountType.asset || acct.type == AccountType.expense;
        totals[line.accountId] = totals[line.accountId]! +
            (isDebit ? (line.debit - line.credit) : (line.credit - line.debit));
      }
    }

    if (totals.isEmpty) return;

    final updatedAccounts = state.accounts.map((a) {
      final computed = totals[a.id];
      if (computed == null) return a;
      return a.copyWith(balance: computed);
    }).toList();

    state = state.copyWith(accounts: updatedAccounts);
    _localStorage.saveAccounts(updatedAccounts);
  }
}

final accountsProvider = StateNotifierProvider<AccountsNotifier, AccountsState>((ref) {
  return AccountsNotifier(ref.read(apiClientProvider), ref);
});

// ============================================================================
// Customers Service - OFFLINE-FIRST
// ============================================================================

class CustomersState {
  final List<Customer> customers;
  final bool isLoading;
  final String? error;

  CustomersState({
    this.customers = const [],
    this.isLoading = false,
    this.error,
  });

  CustomersState copyWith({
    List<Customer>? customers,
    bool? isLoading,
    String? error,
  }) {
    return CustomersState(
      customers: customers ?? this.customers,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class CustomersNotifier extends StateNotifier<CustomersState> {
  final ApiClient _apiClient;
  final Ref _ref;

  CustomersNotifier(this._apiClient, this._ref) : super(CustomersState()) {
    _initializeData();
  }

  Future<void> _initializeData() async {
    state = state.copyWith(isLoading: true);

    // Load from local storage only (no API)
    try {
      final localCustomers = await _localStorage.loadCustomers();
      state = state.copyWith(customers: localCustomers, isLoading: false);
      debugPrint('Loaded ${localCustomers.length} customers from local storage');
    } catch (e) {
      debugPrint('Error loading customers from local storage: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> loadCustomers() async {
    try {
      final localCustomers = await _localStorage.loadCustomers();
      state = state.copyWith(customers: localCustomers, isLoading: false);
    } catch (e) {
      debugPrint('Error loading customers: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  void addCustomer(Customer customer) {
    final updatedCustomers = [...state.customers, customer];
    state = state.copyWith(customers: updatedCustomers);

    _localStorage.saveCustomers(updatedCustomers);

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.create,
      entityType: SyncEntityType.customer,
      entityId: customer.id,
      data: customer.toJson(),
    );
  }

  void updateCustomer(Customer customer) {
    final updatedCustomers = state.customers.map((c) {
      return c.id == customer.id ? customer : c;
    }).toList();
    state = state.copyWith(customers: updatedCustomers);

    _localStorage.saveCustomers(updatedCustomers);

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.update,
      entityType: SyncEntityType.customer,
      entityId: customer.id,
      data: customer.toJson(),
    );
  }
}

final customersProvider = StateNotifierProvider<CustomersNotifier, CustomersState>((ref) {
  return CustomersNotifier(ref.read(apiClientProvider), ref);
});

// ============================================================================
// Vendors Service - OFFLINE-FIRST
// ============================================================================

class VendorsState {
  final List<Vendor> vendors;
  final bool isLoading;
  final String? error;

  VendorsState({
    this.vendors = const [],
    this.isLoading = false,
    this.error,
  });

  VendorsState copyWith({
    List<Vendor>? vendors,
    bool? isLoading,
    String? error,
  }) {
    return VendorsState(
      vendors: vendors ?? this.vendors,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class VendorsNotifier extends StateNotifier<VendorsState> {
  final ApiClient _apiClient;
  final Ref _ref;

  VendorsNotifier(this._apiClient, this._ref) : super(VendorsState()) {
    _initializeData();
  }

  Future<void> _initializeData() async {
    state = state.copyWith(isLoading: true);

    // Load from local storage only (no API)
    try {
      final localVendors = await _localStorage.loadVendors();
      state = state.copyWith(vendors: localVendors, isLoading: false);
      debugPrint('Loaded ${localVendors.length} vendors from local storage');
    } catch (e) {
      debugPrint('Error loading vendors from local storage: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> loadVendors() async {
    try {
      final localVendors = await _localStorage.loadVendors();
      state = state.copyWith(vendors: localVendors, isLoading: false);
    } catch (e) {
      debugPrint('Error loading vendors: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  void addVendor(Vendor vendor) {
    final updatedVendors = [...state.vendors, vendor];
    state = state.copyWith(vendors: updatedVendors);

    _localStorage.saveVendors(updatedVendors);

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.create,
      entityType: SyncEntityType.vendor,
      entityId: vendor.id,
      data: vendor.toJson(),
    );
  }

  void updateVendor(Vendor vendor) {
    final updatedVendors = state.vendors.map((v) {
      return v.id == vendor.id ? vendor : v;
    }).toList();
    state = state.copyWith(vendors: updatedVendors);

    _localStorage.saveVendors(updatedVendors);

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.update,
      entityType: SyncEntityType.vendor,
      entityId: vendor.id,
      data: vendor.toJson(),
    );
  }
}

final vendorsProvider = StateNotifierProvider<VendorsNotifier, VendorsState>((ref) {
  return VendorsNotifier(ref.read(apiClientProvider), ref);
});

// ============================================================================
// Invoices Service - OFFLINE-FIRST
// ============================================================================

class InvoicesState {
  final List<Invoice> invoices;
  final bool isLoading;
  final String? error;

  InvoicesState({
    this.invoices = const [],
    this.isLoading = false,
    this.error,
  });

  InvoicesState copyWith({
    List<Invoice>? invoices,
    bool? isLoading,
    String? error,
  }) {
    return InvoicesState(
      invoices: invoices ?? this.invoices,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class InvoicesNotifier extends StateNotifier<InvoicesState> {
  final ApiClient _apiClient;
  final Ref _ref;

  InvoicesNotifier(this._apiClient, this._ref) : super(InvoicesState()) {
    _initializeData();
  }

  Future<void> _initializeData() async {
    state = state.copyWith(isLoading: true);

    // Load from local storage only (no API)
    try {
      final localInvoices = await _localStorage.loadInvoices();
      state = state.copyWith(invoices: localInvoices, isLoading: false);
      debugPrint('Loaded ${localInvoices.length} invoices from local storage');
    } catch (e) {
      debugPrint('Error loading invoices from local storage: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> loadInvoices() async {
    try {
      final localInvoices = await _localStorage.loadInvoices();
      state = state.copyWith(invoices: localInvoices, isLoading: false);
    } catch (e) {
      debugPrint('Error loading invoices: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  void addInvoice(Invoice invoice) {
    final updatedInvoices = [...state.invoices, invoice];
    state = state.copyWith(invoices: updatedInvoices);
    _localStorage.saveInvoices(updatedInvoices);

    // create_journal_entry: true tells the backend DoubleEntryService to post
    // DR Accounts Receivable / CR Revenue automatically on sync.
    final payload = invoice.toJson()
      ..['create_journal_entry'] = true
      ..['auto_post'] = true;

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.create,
      entityType: SyncEntityType.invoice,
      entityId: invoice.id,
      data: payload,
    );
  }

  void updateInvoice(Invoice invoice) {
    final updatedInvoices = state.invoices.map((i) {
      return i.id == invoice.id ? invoice : i;
    }).toList();
    state = state.copyWith(invoices: updatedInvoices);

    _localStorage.saveInvoices(updatedInvoices);

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.update,
      entityType: SyncEntityType.invoice,
      entityId: invoice.id,
      data: invoice.toJson(),
    );
  }

  void recordPayment(String invoiceId, double amount) {
    final updatedInvoices = state.invoices.map((invoice) {
      if (invoice.id == invoiceId) {
        final newAmountPaid = invoice.amountPaid + amount;
        final newStatus = newAmountPaid >= invoice.total
            ? InvoiceStatus.paid
            : InvoiceStatus.partial;
        return invoice.copyWith(
          amountPaid: newAmountPaid,
          status: newStatus,
          updatedAt: DateTime.now(),
        );
      }
      return invoice;
    }).toList();
    state = state.copyWith(invoices: updatedInvoices);

    _localStorage.saveInvoices(updatedInvoices);

    final invoice = updatedInvoices.firstWhere((i) => i.id == invoiceId);
    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.update,
      entityType: SyncEntityType.invoice,
      entityId: invoiceId,
      data: invoice.toJson(),
    );
  }

  /// Auto-apply a received payment to the customer's oldest open invoices.
  /// Called by PaymentsNotifier.addPayment() when paymentType == received.
  void applyPaymentToCustomer(String customerId, double totalAmount) {
    final openInvoices = state.invoices
        .where((i) =>
            i.customerId == customerId &&
            i.status != InvoiceStatus.paid &&
            i.status != InvoiceStatus.cancelled)
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date)); // oldest first

    if (openInvoices.isEmpty) return;

    var remaining = totalAmount;
    var updatedInvoices = [...state.invoices];

    for (final invoice in openInvoices) {
      if (remaining <= 0) break;
      final balance = invoice.total - invoice.amountPaid;
      if (balance <= 0) continue;
      final applying = remaining.clamp(0.0, balance);
      remaining -= applying;
      final newPaid = invoice.amountPaid + applying;
      updatedInvoices = updatedInvoices.map((i) {
        if (i.id != invoice.id) return i;
        return i.copyWith(
          amountPaid: newPaid,
          status: newPaid >= i.total ? InvoiceStatus.paid : InvoiceStatus.partial,
          updatedAt: DateTime.now(),
        );
      }).toList();
    }

    state = state.copyWith(invoices: updatedInvoices);
    _localStorage.saveInvoices(updatedInvoices);
  }
}

final invoicesProvider = StateNotifierProvider<InvoicesNotifier, InvoicesState>((ref) {
  return InvoicesNotifier(ref.read(apiClientProvider), ref);
});

// ============================================================================
// Bills Service - OFFLINE-FIRST
// ============================================================================

class BillsState {
  final List<Bill> bills;
  final bool isLoading;
  final String? error;

  BillsState({
    this.bills = const [],
    this.isLoading = false,
    this.error,
  });

  BillsState copyWith({
    List<Bill>? bills,
    bool? isLoading,
    String? error,
  }) {
    return BillsState(
      bills: bills ?? this.bills,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class BillsNotifier extends StateNotifier<BillsState> {
  final ApiClient _apiClient;
  final Ref _ref;

  // Resolves once the initial load from disk is done — other providers
  // that need to read the full bill list before doing their own startup
  // work (e.g. asset-draft backfill) must await this first.
  final Completer<void> _loadCompleter = Completer<void>();
  Future<void> get ready => _loadCompleter.future;

  BillsNotifier(this._apiClient, this._ref) : super(BillsState()) {
    _initializeData();
  }

  Future<void> _initializeData() async {
    state = state.copyWith(isLoading: true);

    // Load from local storage only (no API)
    try {
      final localBills = await _localStorage.loadBills();
      state = state.copyWith(bills: localBills, isLoading: false);
      debugPrint('Loaded ${localBills.length} bills from local storage');
    } catch (e) {
      debugPrint('Error loading bills from local storage: $e');
      state = state.copyWith(isLoading: false);
    } finally {
      if (!_loadCompleter.isCompleted) _loadCompleter.complete();
    }
  }

  Future<void> loadBills() async {
    try {
      final localBills = await _localStorage.loadBills();
      state = state.copyWith(bills: localBills, isLoading: false);
    } catch (e) {
      debugPrint('Error loading bills: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  static String _coaCategory(AccountType? type) {
    switch (type) {
      case AccountType.asset:     return 'Asset';
      case AccountType.liability: return 'Liability';
      case AccountType.equity:    return 'Equity';
      case AccountType.revenue:   return 'Revenue';
      case AccountType.expense:   return 'Expense';
      default:                    return 'Expense';
    }
  }

  void addBill(Bill bill) {
    final updatedBills = [...state.bills, bill];
    state = state.copyWith(bills: updatedBills);
    _localStorage.saveBills(updatedBills);

    // Post local GL journal entry immediately (double-entry):
    //   DR  each bill line's expense/asset account (from BillLine.accountId)
    //   CR  Accounts Payable (acct-164) for the bill total
    // This ensures CoA reflects the liability the moment a bill is created.
    final now = DateTime.now();
    final jeId = _uuid.v4();
    final allAccounts = _ref.read(accountsProvider).accounts;
    Account? lookupAcct(String id) => allAccounts
        .cast<Account?>()
        .firstWhere((a) => a?.id == id, orElse: () => null);
    final billLines = <JournalLine>[];
    for (var i = 0; i < bill.lines.length; i++) {
      final l = bill.lines[i];
      if (l.amount <= 0) continue;
      final acc = lookupAcct(l.accountId);
      final category = _coaCategory(acc?.type);
      final lineDesc = l.description.trim().isEmpty ? null : l.description.trim();
      billLines.add(JournalLine(
        id: '$jeId-exp-$i',
        journalEntryId: jeId,
        accountId: l.accountId,
        accountCode: l.accountId.replaceAll('acct-', ''),
        accountName: acc?.name ?? l.accountName ?? l.description,
        debit: l.amount + l.taxAmount,
        credit: 0,
        description: lineDesc != null ? '[$category] $lineDesc' : '[$category]',
      ));
    }
    // Fallback: if no lines (edge case), DR a generic expense account
    if (billLines.isEmpty) {
      billLines.add(JournalLine(
        id: '$jeId-exp-0',
        journalEntryId: jeId,
        accountId: 'acct-125',
        accountCode: '125',
        accountName: 'Operating Expenses',
        debit: bill.total,
        credit: 0,
        description: '[Expense]',
      ));
    }
    billLines.add(JournalLine(
      id: '$jeId-ap',
      journalEntryId: jeId,
      accountId: 'acct-164',
      accountCode: '164',
      accountName: 'Accounts Payable',
      debit: 0,
      credit: bill.total,
      description: '[Liability] Payable to ${bill.vendorName ?? bill.vendorId}',
    ));
    _ref.read(journalsProvider.notifier).addEntry(JournalEntry(
      id: jeId,
      entryNumber: 'BILL-JE-${bill.billNumber}',
      date: bill.date,
      description: 'Bill ${bill.billNumber} — ${bill.vendorName ?? bill.vendorId}',
      reference: bill.reference ?? bill.billNumber,
      status: JournalEntryStatus.posted,
      lines: billLines,
      createdAt: now,
      updatedAt: now,
    ));

    // create_journal_entry: true tells the backend DoubleEntryService to post
    // DR Expense / CR Accounts Payable automatically on sync.
    final payload = bill.toJson()
      ..['create_journal_entry'] = true
      ..['auto_post'] = true;

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.create,
      entityType: SyncEntityType.bill,
      entityId: bill.id,
      data: payload,
    );
  }

  /// Delete a bill and post a reversal journal entry to undo the original
  /// DR Expense / CR Accounts Payable double-entry created by [addBill].
  void deleteBill(String billId) {
    final billIndex = state.bills.indexWhere((b) => b.id == billId);
    if (billIndex == -1) return;
    final bill = state.bills[billIndex];

    final updatedBills = state.bills.where((b) => b.id != billId).toList();
    state = state.copyWith(bills: updatedBills);
    _localStorage.saveBills(updatedBills);

    // Post reversal JE: DR Accounts Payable / CR each expense account.
    final now = DateTime.now();
    final jeId = _uuid.v4();
    final allAccounts = _ref.read(accountsProvider).accounts;
    Account? lookupAcct(String id) =>
        allAccounts.cast<Account?>().firstWhere((a) => a?.id == id, orElse: () => null);

    final reversalLines = <JournalLine>[];
    for (var i = 0; i < bill.lines.length; i++) {
      final l = bill.lines[i];
      if (l.amount <= 0) continue;
      final acc = lookupAcct(l.accountId);
      reversalLines.add(JournalLine(
        id: '$jeId-rev-$i',
        journalEntryId: jeId,
        accountId: l.accountId,
        accountCode: l.accountId.replaceAll('acct-', ''),
        accountName: acc?.name ?? l.accountName ?? l.description,
        debit: 0,
        credit: l.amount + l.taxAmount,
        description: '[Reversal] ${l.description}',
      ));
    }
    if (reversalLines.isEmpty) {
      reversalLines.add(JournalLine(
        id: '$jeId-rev-0',
        journalEntryId: jeId,
        accountId: 'acct-125',
        accountCode: '125',
        accountName: 'Operating Expenses',
        debit: 0,
        credit: bill.total,
        description: '[Reversal]',
      ));
    }
    reversalLines.add(JournalLine(
      id: '$jeId-rev-ap',
      journalEntryId: jeId,
      accountId: 'acct-164',
      accountCode: '164',
      accountName: 'Accounts Payable',
      debit: bill.total,
      credit: 0,
      description: '[Reversal] ${bill.vendorName ?? bill.vendorId}',
    ));

    _ref.read(journalsProvider.notifier).addEntry(JournalEntry(
      id: jeId,
      entryNumber: 'VOID-BILL-${bill.billNumber}',
      date: now,
      description: 'Void Bill ${bill.billNumber} — ${bill.vendorName ?? bill.vendorId}',
      reference: 'VOID-${bill.billNumber}',
      status: JournalEntryStatus.posted,
      lines: reversalLines,
      createdAt: now,
      updatedAt: now,
    ));

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.delete,
      entityType: SyncEntityType.bill,
      entityId: billId,
      data: {'id': billId},
    );
  }

  void updateBill(Bill bill) {
    final updatedBills = state.bills.map((b) {
      return b.id == bill.id ? bill : b;
    }).toList();
    state = state.copyWith(bills: updatedBills);
    _localStorage.saveBills(updatedBills);

    // ── Sync linked GL journal entry ──────────────────────────────────────
    final jeNumber = 'BILL-JE-${bill.billNumber}';
    final allEntries = _ref.read(journalsProvider).entries;
    final existingJE = allEntries.cast<JournalEntry?>().firstWhere(
      (e) => e?.entryNumber == jeNumber,
      orElse: () => null,
    );
    if (existingJE != null) {
      final allAccounts = _ref.read(accountsProvider).accounts;
      Account? lookupAcct(String id) => allAccounts
          .cast<Account?>()
          .firstWhere((a) => a?.id == id, orElse: () => null);

      final updatedLines = <JournalLine>[];
      for (var i = 0; i < bill.lines.length; i++) {
        final l = bill.lines[i];
        if (l.amount <= 0) continue;
        final acc = lookupAcct(l.accountId);
        final category = _coaCategory(acc?.type);
        final lineDesc = l.description.trim().isEmpty ? null : l.description.trim();
        updatedLines.add(JournalLine(
          id: '${existingJE.id}-exp-$i',
          journalEntryId: existingJE.id,
          accountId: l.accountId,
          accountCode: l.accountId.replaceAll('acct-', ''),
          accountName: acc?.name ?? l.accountName ?? l.description,
          debit: l.amount + l.taxAmount,
          credit: 0,
          description: lineDesc != null ? '[$category] $lineDesc' : '[$category]',
        ));
      }
      if (updatedLines.isEmpty) {
        updatedLines.add(JournalLine(
          id: '${existingJE.id}-exp-0',
          journalEntryId: existingJE.id,
          accountId: 'acct-125',
          accountCode: '125',
          accountName: 'Operating Expenses',
          debit: bill.total,
          credit: 0,
          description: '[Expense]',
        ));
      }
      updatedLines.add(JournalLine(
        id: '${existingJE.id}-ap',
        journalEntryId: existingJE.id,
        accountId: 'acct-164',
        accountCode: '164',
        accountName: 'Accounts Payable',
        debit: 0,
        credit: bill.total,
        description: '[Liability] Payable to ${bill.vendorName ?? bill.vendorId}',
      ));

      _ref.read(journalsProvider.notifier).updateEntry(
        existingJE.copyWith(
          date: bill.date,
          description: 'Bill ${bill.billNumber} — ${bill.vendorName ?? bill.vendorId}',
          lines: updatedLines,
          updatedAt: DateTime.now(),
        ),
      );
    }

    // ── Sync linked AssetDraft (if any bill line is a fixed-asset account) ─
    final billAccounts = _ref.read(accountsProvider).accounts;
    Account? lookupBillAcct(String id) => billAccounts
        .cast<Account?>()
        .firstWhere((a) => a?.id == id, orElse: () => null);

    bool _isFixedAssetAcct(Account? a) =>
        a != null &&
        a.type == AccountType.asset &&
        (a.subType == AccountSubType.fixedAsset ||
            a.subType == AccountSubType.otherAsset ||
            a.subType == AccountSubType.otherCurrentAsset);

    String _inferCategory(Account acct) {
      final n = acct.name.toLowerCase();
      if (n.contains('vehicle') || n.contains('motor') || n.contains('car')) return 'Vehicle';
      if (n.contains('furniture') || n.contains('fittings')) return 'Furniture';
      if (n.contains('computer') || n.contains('laptop') || n.contains('electronic') || n.contains('phone')) return 'Electronics';
      if (n.contains('building') || n.contains('premises') || n.contains('property')) return 'Building';
      if (n.contains('land') || n.contains('plot')) return 'Land';
      if (n.contains('machine') || n.contains('machinery') || n.contains('plant')) return 'Machinery';
      return 'Equipment';
    }

    final billRef = (bill.reference?.trim().isNotEmpty ?? false)
        ? bill.reference!
        : bill.billNumber;

    // ── Path 1: bill was created with an explicit asset category dropdown ─
    if (isAssetCategory(bill.category)) {
      final assetName = (bill.vendorName?.isNotEmpty ?? false)
          ? '${bill.category} — ${bill.vendorName}'
          : bill.category!;
      _ref.read(assetDraftsProvider.notifier).updateDraftByBillRef(
        billRef,
        amount: bill.subtotal,
        assetName: assetName,
        vendorName: bill.vendorName,
        date: bill.date,
        id: bill.id,
        category: bill.category!,
        currency: bill.currencyCode,
      );
    }

    for (var i = 0; i < bill.lines.length; i++) {
      final l = bill.lines[i];
      if (l.amount <= 0) continue;
      final acct = lookupBillAcct(l.accountId);
      if (!_isFixedAssetAcct(acct)) continue;
      final category = _inferCategory(acct!);
      final assetName = l.description.trim().isNotEmpty
          ? l.description.trim()
          : bill.vendorName != null && bill.vendorName!.isNotEmpty
              ? '${acct.name} — ${bill.vendorName}'
              : acct.name;
      _ref.read(assetDraftsProvider.notifier).updateDraftByBillRef(
        billRef,
        amount: l.amount,
        assetName: assetName,
        vendorName: bill.vendorName,
        date: bill.date,
        id: '${bill.id}_${l.id}',
        category: category,
        currency: bill.currencyCode,
      );
    }

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.update,
      entityType: SyncEntityType.bill,
      entityId: bill.id,
      data: bill.toJson(),
    );
  }

  void recordPayment(String billId, double amount) {
    final updatedBills = state.bills.map((bill) {
      if (bill.id == billId) {
        final newAmountPaid = bill.amountPaid + amount;
        final newStatus = newAmountPaid >= bill.total
            ? BillStatus.paid
            : BillStatus.partial;
        return bill.copyWith(
          amountPaid: newAmountPaid,
          status: newStatus,
          updatedAt: DateTime.now(),
        );
      }
      return bill;
    }).toList();
    state = state.copyWith(bills: updatedBills);

    _localStorage.saveBills(updatedBills);

    final bill = updatedBills.firstWhere((b) => b.id == billId);
    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.update,
      entityType: SyncEntityType.bill,
      entityId: billId,
      data: bill.toJson(),
    );
  }

  /// Reverse a previously recorded payment (e.g., when a reconciled bank
  /// statement is deleted). Reduces amountPaid and resets status accordingly.
  void reversePayment(String billId, double amount) {
    final updatedBills = state.bills.map((bill) {
      if (bill.id == billId) {
        final newAmountPaid = (bill.amountPaid - amount).clamp(0.0, bill.total);
        final BillStatus newStatus;
        if (newAmountPaid <= 0) {
          newStatus = BillStatus.pending;
        } else if (newAmountPaid >= bill.total) {
          newStatus = BillStatus.paid;
        } else {
          newStatus = BillStatus.partial;
        }
        return bill.copyWith(
          amountPaid: newAmountPaid,
          status: newStatus,
          updatedAt: DateTime.now(),
        );
      }
      return bill;
    }).toList();
    state = state.copyWith(bills: updatedBills);
    _localStorage.saveBills(updatedBills);

    // Sync only if the bill is still present (it may have been deleted).
    final billIdx = updatedBills.indexWhere((b) => b.id == billId);
    if (billIdx < 0) return;
    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.update,
      entityType: SyncEntityType.bill,
      entityId: billId,
      data: updatedBills[billIdx].toJson(),
    );
  }

  /// Auto-apply a made payment to the vendor's earliest-due open bills.
  /// Called by PaymentsNotifier.addPayment() when paymentType == made.
  void applyPaymentToVendor(String vendorId, double totalAmount) {
    final openBills = state.bills
        .where((b) =>
            b.vendorId == vendorId &&
            b.status != BillStatus.paid &&
            b.status != BillStatus.cancelled)
        .toList()
      ..sort((a, b) => a.dueDate.compareTo(b.dueDate)); // earliest due first

    if (openBills.isEmpty) return;

    var remaining = totalAmount;
    var updatedBills = [...state.bills];

    for (final bill in openBills) {
      if (remaining <= 0) break;
      final balance = bill.total - bill.amountPaid;
      if (balance <= 0) continue;
      final applying = remaining.clamp(0.0, balance);
      remaining -= applying;
      final newPaid = bill.amountPaid + applying;
      updatedBills = updatedBills.map((b) {
        if (b.id != bill.id) return b;
        return b.copyWith(
          amountPaid: newPaid,
          status: newPaid >= b.total ? BillStatus.paid : BillStatus.partial,
          updatedAt: DateTime.now(),
        );
      }).toList();
    }

    state = state.copyWith(bills: updatedBills);
    _localStorage.saveBills(updatedBills);
  }
}

final billsProvider = StateNotifierProvider<BillsNotifier, BillsState>((ref) {
  return BillsNotifier(ref.read(apiClientProvider), ref);
});

// ============================================================================
// Uganda PAYE computation (monthly gross salary → monthly PAYE deduction)
// Source: Income Tax Act (Uganda), effective 2024 monthly bands
// ============================================================================

double _computeUgandaPAYE(double grossMonthly) {
  if (grossMonthly <= 235000) return 0;
  if (grossMonthly <= 335000) return (grossMonthly - 235000) * 0.10;
  if (grossMonthly <= 410000) return (100000 * 0.10) + (grossMonthly - 335000) * 0.20;
  return (100000 * 0.10) + (75000 * 0.20) + (grossMonthly - 410000) * 0.30;
}

// ============================================================================
// Journal Entries Service - OFFLINE-FIRST
// ============================================================================

class JournalsState {
  final List<JournalEntry> entries;
  final bool isLoading;
  final String? error;

  JournalsState({
    this.entries = const [],
    this.isLoading = false,
    this.error,
  });

  JournalsState copyWith({
    List<JournalEntry>? entries,
    bool? isLoading,
    String? error,
  }) {
    return JournalsState(
      entries: entries ?? this.entries,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class JournalsNotifier extends StateNotifier<JournalsState> {
  final ApiClient _apiClient;
  final Ref _ref;

  /// Resolves once the real journals file has finished loading from disk.
  /// Every read-modify-write below (addEntry/addEntries) MUST await this
  /// before treating state.entries as the full picture — see addEntries()
  /// for why.
  late final Future<void> ready;

  JournalsNotifier(this._apiClient, this._ref) : super(JournalsState()) {
    ready = _initializeData();
  }

  Future<void> _initializeData() async {
    state = state.copyWith(isLoading: true);

    // Load from local storage only (no API)
    try {
      final localEntries = await _localStorage.loadJournalEntries();
      state = state.copyWith(entries: localEntries, isLoading: false);
      debugPrint('Loaded ${localEntries.length} journal entries from local storage');
    } catch (e) {
      debugPrint('Error loading journals from local storage: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> loadJournals() async {
    try {
      final localEntries = await _localStorage.loadJournalEntries();
      state = state.copyWith(entries: localEntries, isLoading: false);
    } catch (e) {
      debugPrint('Error loading journals: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> addEntry(JournalEntry entry) async {
    // JournalsNotifier starts with an empty in-memory list and loads the
    // real (possibly 20MB+) file from disk asynchronously in the
    // background. Building "state.entries + this new entry" before that
    // load finishes silently overwrites the entire real journals file with
    // just the new entry — indistinguishable from data loss. Always wait
    // for the real data first.
    await ready;
    final updatedEntries = [...state.entries, entry];
    state = state.copyWith(entries: updatedEntries);

    _localStorage.saveJournalEntries(updatedEntries);

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.create,
      entityType: SyncEntityType.journalEntry,
      entityId: entry.id,
      data: entry.toJson(),
    );

    // Immediately recompute CoA account balances so the Chart of Accounts
    // and reports reflect this JE before the next server sync.
    if (entry.status == JournalEntryStatus.posted) {
      _ref.read(accountsProvider.notifier).recomputeBalancesFromJournals(updatedEntries);
    }

    // Auto-generate employer NSSF JE for posted salary entries (Uganda NSSF Act)
    if (entry.status == JournalEntryStatus.posted) {
      _createPayrollTaxJEs(entry);
    }
  }

  /// Adds several journal entries as a single batch — ONE save and ONE
  /// balance recompute for the whole batch, instead of calling addEntry()
  /// per entry. That matters a lot once the journal file is large: each
  /// save re-reads and re-decodes the existing file (to guard against a
  /// catastrophic-drop save) before re-encoding and writing the full array
  /// back — fine once, but calling that in a tight loop (e.g. back-filling
  /// depreciation across many overdue months for many assets) meant doing
  /// that full read+decode+encode+write cycle dozens of times in rapid
  /// succession on a multi-MB file, which is exactly what made "run
  /// depreciation" look like it corrupted the data afterward.
  ///
  /// That batching fix alone was not enough: the real trigger, reproduced
  /// live, was Marion running depreciation as her very first action right
  /// after opening the app — before the existing 22,000+ journal entries
  /// had finished loading from disk into this notifier's in-memory state
  /// (which starts empty and loads in the background). addEntries() built
  /// its "modify" half off that still-empty state.entries and then saved
  /// the result, silently overwriting the entire real journals file with
  /// just the handful of new depreciation entries — which is exactly what
  /// "reports blank, bank balance disappeared" looks like from the app
  /// side. Always wait for the real data to finish loading first.
  Future<void> addEntries(List<JournalEntry> entries) async {
    if (entries.isEmpty) return;

    await ready;
    final updatedEntries = [...state.entries, ...entries];
    state = state.copyWith(entries: updatedEntries);

    _localStorage.saveJournalEntries(updatedEntries);

    for (final entry in entries) {
      _ref.read(syncServiceProvider.notifier).queueChange(
        action: SyncAction.create,
        entityType: SyncEntityType.journalEntry,
        entityId: entry.id,
        data: entry.toJson(),
      );
    }

    if (entries.any((e) => e.status == JournalEntryStatus.posted)) {
      _ref.read(accountsProvider.notifier).recomputeBalancesFromJournals(updatedEntries);
    }

    for (final entry in entries) {
      if (entry.status == JournalEntryStatus.posted) {
        _createPayrollTaxJEs(entry);
      }
    }
  }

  /// Generates the employer NSSF expense JE (10% of gross salary) for any posted
  /// journal entry that debits account 132 (Salaries). Also notes PAYE and
  /// employee NSSF (5%) amounts in the description for URA filing reference.
  void _createPayrollTaxJEs(JournalEntry salaryEntry) {
    // Respect user setting — skip if auto-journalization is disabled
    if (!_ref.read(appSettingsProvider).autoPayrollNSSFJE) return;

    final grossSalary = salaryEntry.lines
        .where((l) => l.accountId == 'acct-132')
        .fold(0.0, (s, l) => s + l.debit);
    if (grossSalary <= 0) return;

    // Idempotency guard — don't create twice for the same salary JE
    final refKey = 'JE-PAYR-${salaryEntry.id}';
    if (state.entries.any((e) => e.reference == refKey)) return;

    final paye = _computeUgandaPAYE(grossSalary);
    final empNSSF = grossSalary * 0.05;
    final emplrNSSF = grossSalary * 0.10;
    final now = DateTime.now();
    final jeId = const Uuid().v4();

    // Employer NSSF: DR 135 Employer Contribution NSSF, CR 149 NSSF Payable
    // (Employee NSSF 5% and PAYE are employee deductions recorded in original JE;
    //  amounts listed here for URA/NSSF filing reference.)
    final payrollJE = JournalEntry(
      id: jeId,
      entryNumber: 'AUTO-PAYR-${now.millisecondsSinceEpoch}',
      date: salaryEntry.date,
      description: 'Auto: Employer NSSF (10%) for ${salaryEntry.entryNumber}. '
          'Ref: PAYE due UGX ${paye.toStringAsFixed(0)}, '
          'Employee NSSF (5%) UGX ${empNSSF.toStringAsFixed(0)}, '
          'Employer NSSF (10%) UGX ${emplrNSSF.toStringAsFixed(0)}.',
      reference: refKey,
      status: JournalEntryStatus.posted,
      lines: [
        JournalLine(
          id: '$jeId-1',
          journalEntryId: jeId,
          accountId: 'acct-135',
          accountCode: '135',
          accountName: 'Employer Contribution NSSF',
          debit: emplrNSSF,
          credit: 0,
        ),
        JournalLine(
          id: '$jeId-2',
          journalEntryId: jeId,
          accountId: 'acct-149',
          accountCode: '149',
          accountName: 'NSSF Payable',
          debit: 0,
          credit: emplrNSSF,
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );

    addEntry(payrollJE);
  }

  void postEntry(String entryId) {
    final updatedEntries = state.entries.map((e) {
      if (e.id == entryId) {
        return e.copyWith(
          status: JournalEntryStatus.posted,
          updatedAt: DateTime.now(),
        );
      }
      return e;
    }).toList();
    state = state.copyWith(entries: updatedEntries);

    _localStorage.saveJournalEntries(updatedEntries);

    final entry = updatedEntries.firstWhere((e) => e.id == entryId);
    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.update,
      entityType: SyncEntityType.journalEntry,
      entityId: entryId,
      data: entry.toJson(),
    );
  }

  void reverseEntry(String entryId, DateTime reversalDate) {
    final idx = state.entries.indexWhere((e) => e.id == entryId);
    if (idx == -1) return;
    final original = state.entries[idx];
    if (original.isReversed) return;

    final now = DateTime.now();
    const uuid = Uuid();
    final revId = uuid.v4();

    final reversalEntry = JournalEntry(
      id: revId,
      entryNumber: 'REV-${original.entryNumber}',
      date: reversalDate,
      description: 'Reversal of ${original.entryNumber} — ${original.description}',
      reference: original.reference,
      status: JournalEntryStatus.posted,
      reversesEntryId: original.id,
      lines: original.lines.map((l) => JournalLine(
        id: '$revId-${l.id}',
        journalEntryId: revId,
        accountId: l.accountId,
        accountName: l.accountName,
        accountCode: l.accountCode,
        debit: l.credit,
        credit: l.debit,
        description: l.description,
      )).toList(),
      createdAt: now,
      updatedAt: now,
    );

    final markedOriginal = original.copyWith(reversedById: revId, updatedAt: now);

    final updated = [...state.entries];
    updated[idx] = markedOriginal;
    state = state.copyWith(entries: updated);
    _localStorage.saveJournalEntries(updated);
    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.update,
      entityType: SyncEntityType.journalEntry,
      entityId: entryId,
      data: markedOriginal.toJson(),
    );
    _ref.read(accountsProvider.notifier).recomputeBalancesFromJournals(updated);

    addEntry(reversalEntry);
  }

  void updateEntry(JournalEntry entry) {
    final updatedEntries = state.entries
        .map((e) => e.id == entry.id ? entry : e)
        .toList();
    state = state.copyWith(entries: updatedEntries);
    _localStorage.saveJournalEntries(updatedEntries);
    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.update,
      entityType: SyncEntityType.journalEntry,
      entityId: entry.id,
      data: entry.toJson(),
    );
    if (entry.status == JournalEntryStatus.posted) {
      _ref.read(accountsProvider.notifier).recomputeBalancesFromJournals(updatedEntries);
    }
  }

  /// Removes journal entries by ID — called when a bank statement is deleted
  /// so reports immediately reflect the reversal.
  void removeEntries(List<String> ids) {
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    final updated = state.entries.where((e) => !idSet.contains(e.id)).toList();
    state = state.copyWith(entries: updated);
    _localStorage.saveJournalEntries(updated);
    _ref.read(accountsProvider.notifier).recomputeBalancesFromJournals(updated);
  }
}

final journalsProvider = StateNotifierProvider<JournalsNotifier, JournalsState>((ref) {
  return JournalsNotifier(ref.read(apiClientProvider), ref);
});

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Forces every core data provider to reload directly from disk. Any restore
// (server pull or local .thirdbooks file import) writes straight to the
// JSON files via LocalStorageService — it does NOT touch the already-running
// app's in-memory provider state on its own. Without calling this
// afterward, the files on disk are correctly restored but the UI keeps
// showing whatever was in memory before the restore until the app is fully
// closed and reopened — which looks exactly like "the restore didn't work"
// even though it did. Takes a generic reader so it works from both a
// ConsumerState's `ref.read` and a plain State's `ProviderContainer.read`.
// ---------------------------------------------------------------------------
Future<void> reloadAllCoreProviders(
    T Function<T>(ProviderListenable<T> provider) read) async {
  try {
    await read(accountsProvider.notifier).loadAccounts();
    await read(customersProvider.notifier).loadCustomers();
    await read(vendorsProvider.notifier).loadVendors();
    await read(invoicesProvider.notifier).loadInvoices();
    await read(billsProvider.notifier).loadBills();
    await read(journalsProvider.notifier).loadJournals();
    await read(paymentsProvider.notifier).loadPayments();
  } catch (_) {
    // Best-effort — a failed reload here must never mask the restore's
    // own success/failure result.
  }
}

// ---------------------------------------------------------------------------
// Ledger Balances — derived from posted journal entries
// ---------------------------------------------------------------------------
// Returns { accountId → (∑ debits − ∑ credits) } for every posted JE.
// Debit-normal accounts (Asset, Expense) → positive value means Dr balance.
// Credit-normal accounts (Liability, Equity, Revenue) → negative value means
// Cr balance (i.e. the presentational balance = −raw value).
final ledgerBalancesProvider = Provider<Map<String, double>>((ref) {
  final entries = ref.watch(journalsProvider).entries;
  final raw = <String, double>{};
  for (final entry in entries) {
    if (entry.status != JournalEntryStatus.posted) continue;
    for (final line in entry.lines) {
      // Normalize to 'acct-{code}' when a code is present, same as the
      // Cash Flow report's ledger computation — different screens have
      // historically stored either the account's real ID or the
      // 'acct-{code}' convenience string in accountId, so keying only by
      // the raw accountId (as this used to) silently dropped balance
      // contributions from whichever convention wasn't used for a given
      // line, e.g. bank account balances showing 0 despite real posted
      // transactions.
      final key = line.accountCode != null ? 'acct-${line.accountCode}' : line.accountId;
      raw[key] = (raw[key] ?? 0) + line.debit - line.credit;
    }
  }
  return raw;
});

// Returns the presentational balance for [account] given ledger raw values.
// Positive result = balance in the normal direction for that account type.
double ledgerPresentationalBalance(Account account, Map<String, double> raw) {
  final r = raw['acct-${account.code}'] ?? raw[account.id] ?? 0.0;
  return account.isDebitNormal ? r : -r;
}



class PaymentsState {
  final List<Payment> payments;
  final bool isLoading;
  final String? error;

  PaymentsState({
    this.payments = const [],
    this.isLoading = false,
    this.error,
  });

  PaymentsState copyWith({
    List<Payment>? payments,
    bool? isLoading,
    String? error,
  }) {
    return PaymentsState(
      payments: payments ?? this.payments,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class PaymentsNotifier extends StateNotifier<PaymentsState> {
  final ApiClient _apiClient;
  final Ref _ref;

  PaymentsNotifier(this._apiClient, this._ref) : super(PaymentsState()) {
    _initializeData();
  }

  Future<void> _initializeData() async {
    state = state.copyWith(isLoading: true);

    // Load from local storage only (no API)
    try {
      final localPayments = await _localStorage.loadPayments();
      state = state.copyWith(payments: localPayments, isLoading: false);
      debugPrint('Loaded ${localPayments.length} payments from local storage');
    } catch (e) {
      debugPrint('Error loading payments from local storage: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> loadPayments() async {
    try {
      final localPayments = await _localStorage.loadPayments();
      state = state.copyWith(payments: localPayments, isLoading: false);
    } catch (e) {
      debugPrint('Error loading payments: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  void addPayment(Payment payment) {
    final updatedPayments = [...state.payments, payment];
    state = state.copyWith(payments: updatedPayments);
    _localStorage.savePayments(updatedPayments);

    // Auto-apply to open invoices (received) or bills (made) so that
    // A/R and A/P balances update immediately without a separate step.
    if (payment.paymentType == PaymentType.received &&
        payment.customerId != null) {
      _ref
          .read(invoicesProvider.notifier)
          .applyPaymentToCustomer(payment.customerId!, payment.amount);
    } else if (payment.paymentType == PaymentType.made &&
        payment.vendorId != null) {
      _ref
          .read(billsProvider.notifier)
          .applyPaymentToVendor(payment.vendorId!, payment.amount);
      // Auto-generate WHT JE (6% on supplier payment) if enabled
      _createWHTJE(payment);
    }

    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.create,
      entityType: SyncEntityType.payment,
      entityId: payment.id,
      data: payment.toJson(),
    );
  }

  /// Records a payment for history/display only — no auto-apply side effects.
  /// Use this when the payment has already been applied to the bill directly
  /// (e.g. via recordPayment in bank reconciliation) to avoid double-counting.
  void recordPaymentHistory(Payment payment) {
    final updatedPayments = [...state.payments, payment];
    state = state.copyWith(payments: updatedPayments);
    _localStorage.savePayments(updatedPayments);
    _ref.read(syncServiceProvider.notifier).queueChange(
      action: SyncAction.create,
      entityType: SyncEntityType.payment,
      entityId: payment.id,
      data: payment.toJson(),
    );
  }

  /// Auto-creates a 6% Withholding Tax JE for supplier payments (Uganda WHT).
  /// Triggered only when autoWHTJE is enabled in settings.
  /// DR 144 Withholding Tax / CR 146 Withholding Tax Payable — Suppliers.
  void _createWHTJE(Payment payment) {
    if (!_ref.read(appSettingsProvider).autoWHTJE) return;
    if (payment.amount <= 0) return;

    // Idempotency: one WHT JE per payment
    final refKey = 'JE-WHT-${payment.id}';
    final existingEntries = _ref.read(journalsProvider).entries;
    if (existingEntries.any((e) => e.reference == refKey)) return;

    final whtAmount = payment.amount * 0.06;
    final now = DateTime.now();
    final jeId = const Uuid().v4();

    final whtJE = JournalEntry(
      id: jeId,
      entryNumber: 'AUTO-WHT-${now.millisecondsSinceEpoch}',
      date: payment.paymentDate,
      description: 'Auto: WHT (6%) on supplier payment '
          '${payment.reference ?? payment.id}. '
          'Gross: UGX ${payment.amount.toStringAsFixed(0)}, '
          'WHT: UGX ${whtAmount.toStringAsFixed(0)}.',
      reference: refKey,
      status: JournalEntryStatus.posted,
      lines: [
        JournalLine(
          id: '$jeId-1',
          journalEntryId: jeId,
          accountId: 'acct-144',
          accountCode: '144',
          accountName: 'Withholding Tax',
          debit: whtAmount,
          credit: 0,
        ),
        JournalLine(
          id: '$jeId-2',
          journalEntryId: jeId,
          accountId: 'acct-146',
          accountCode: '146',
          accountName: 'Withholding Tax Payable — Suppliers',
          debit: 0,
          credit: whtAmount,
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );

    _ref.read(journalsProvider.notifier).addEntry(whtJE);
  }
}

final paymentsProvider = StateNotifierProvider<PaymentsNotifier, PaymentsState>((ref) {
  return PaymentsNotifier(ref.read(apiClientProvider), ref);
});

// ============================================================================
// Outlets Service - Database Stream
// ============================================================================

/// Stream provider that watches outlets from database in real-time
final outletsStreamProvider = StreamProvider<List<Outlet>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.watchAllOutlets();
});

/// Get active outlets count
final activeOutletsCountProvider = Provider<int>((ref) {
  final outletsAsync = ref.watch(outletsStreamProvider);
  return outletsAsync.when(
    data: (outlets) => outlets.where((o) => o.isActive).length,
    loading: () => 0,
    error: (_, __) => 0,
  );
});

/// Get outlets by region
final outletsByRegionProvider = Provider.family<List<Outlet>, String>((ref, region) {
  final outletsAsync = ref.watch(outletsStreamProvider);
  return outletsAsync.when(
    data: (outlets) {
      if (region == 'All') return outlets;
      return outlets.where((o) => o.region == region).toList();
    },
    loading: () => [],
    error: (_, __) => [],
  );
});

/// Sorted outlets stream (by outlet code/ID)
final sortedOutletsStreamProvider = Provider<Stream<List<Outlet>>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.watchAllOutlets().map((outlets) {
    outlets.sort((a, b) => a.outletCode.compareTo(b.outletCode));
    return outlets;
  });
});

// ============================================================================
// CSV Import Service - Import AccountingTotalsInOut.csv
// ============================================================================

class CsvImportResult {
  final int totalRows;
  final int importedRows;
  final int skippedRows;
  final int journalEntriesCreated;
  final List<String> errors;

  CsvImportResult({
    required this.totalRows,
    required this.importedRows,
    required this.skippedRows,
    required this.journalEntriesCreated,
    required this.errors,
  });
}

/// CSV Import state
class CsvImportState {
  final bool isImporting;
  final CsvImportResult? lastResult;
  final String? error;
  final double progress;

  CsvImportState({
    this.isImporting = false,
    this.lastResult,
    this.error,
    this.progress = 0,
  });

  CsvImportState copyWith({
    bool? isImporting,
    CsvImportResult? lastResult,
    String? error,
    double? progress,
  }) {
    return CsvImportState(
      isImporting: isImporting ?? this.isImporting,
      lastResult: lastResult ?? this.lastResult,
      error: error,
      progress: progress ?? this.progress,
    );
  }
}

class CsvImportNotifier extends StateNotifier<CsvImportState> {
  final AppDatabase _db;
  final Ref _ref;

  CsvImportNotifier(this._db, this._ref) : super(CsvImportState());

  /// Parse a number string like " 746,000 " or " 1,585,000 " to double
  double _parseAmount(String raw) {
    final cleaned = raw.trim().replaceAll(',', '').replaceAll(' ', '');
    return double.tryParse(cleaned) ?? 0.0;
  }

  /// Parse date in m/d/yyyy format
  DateTime? _parseDate(String raw) {
    try {
      final trimmed = raw.trim();
      final parts = trimmed.split('/');
      if (parts.length == 3) {
        final month = int.parse(parts[0]);
        final day = int.parse(parts[1]);
        final year = int.parse(parts[2]);
        return DateTime(year, month, day);
      }
    } catch (_) {}
    return null;
  }

  /// Normalize CSV outlet code for DB lookup
  /// DB stores full codes like "23103000", CSV has same format
  String _mapOutletCode(String csvCode) {
    return csvCode.trim();
  }

  /// Import CSV file and create outlet revenue entries + journal entries
  Future<CsvImportResult> importCsvFile(String filePath) async {
    state = state.copyWith(isImporting: true, progress: 0, error: null);

    int totalRows = 0;
    int importedRows = 0;
    int skippedRows = 0;
    int journalEntriesCreated = 0;
    final errors = <String>[];

    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('File not found: $filePath');
      }

      final lines = await file.readAsLines();
      if (lines.isEmpty) {
        throw Exception('CSV file is empty');
      }

      // Skip header row
      totalRows = lines.length - 1;

      // Get all outlets for mapping
      final outlets = await _db.getAllOutlets();
      final outletMap = <String, Outlet>{};
      for (final outlet in outlets) {
        outletMap[outlet.outletCode] = outlet;
      }

      // Cache existing revenue records to detect duplicates within this import
      // and against the database (prevents re-importing the same CSV file).
      // Key: "{outletId}|{yyyyMMdd}"
      final existingRevenues = await _db.getAllOutletRevenues();
      final existingKeys = <String>{};
      for (final r in existingRevenues) {
        existingKeys.add(
            '${r.outletId}|${DateFormat('yyyyMMdd').format(r.date)}');
      }

      // Track journal entries to create
      final journalEntries = <JournalEntry>[];
      int jeCounter = 0;

      for (var i = 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) {
          skippedRows++;
          continue;
        }

        try {
          // Parse CSV line (handle quoted fields with commas)
          final fields = _parseCsvLine(line);
          if (fields.length < 5) {
            errors.add('Row ${i + 1}: Not enough columns (${fields.length})');
            skippedRows++;
            continue;
          }

          final csvOutletCode = fields[0].trim();
          final dateStr = fields[1].trim();
          final totalIn = _parseAmount(fields[2]);
          final totalOut = _parseAmount(fields[3]);
          final totalGGR = _parseAmount(fields[4]);

          // Map outlet code
          final outletCode = _mapOutletCode(csvOutletCode);
          final outlet = outletMap[outletCode];

          if (outlet == null) {
            errors.add('Row ${i + 1}: Outlet $outletCode not found');
            skippedRows++;
            continue;
          }

          // Parse date
          final date = _parseDate(dateStr);
          if (date == null) {
            errors.add('Row ${i + 1}: Invalid date "$dateStr"');
            skippedRows++;
            continue;
          }

          // Deduplication: skip if this outlet+date was already imported
          final dupKey = '${outlet.id}|${DateFormat('yyyyMMdd').format(date)}';
          if (existingKeys.contains(dupKey)) {
            skippedRows++;
            state = state.copyWith(progress: i / totalRows);
            continue;
          }
          existingKeys.add(dupKey); // guard against within-file duplicates

          // Create OutletRevenue entry
          // amount = Total In, commissionAmount = Total Out, netAmount = GGR
          final revenueId = _uuid.v4();
          final revenue = OutletRevenuesCompanion.insert(
            id: revenueId,
            outletId: outlet.id,
            date: date,
            amount: Value(totalIn),
            commissionAmount: Value(totalOut),
            netAmount: Value(totalGGR),
            description: Value('CSV Import: ${outlet.name} - ${DateFormat('MMM d, yyyy').format(date)}'),
            reference: Value('CSV-$csvOutletCode-${DateFormat('yyyyMMdd').format(date)}'),
            status: const Value('recorded'),
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );

          await _db.insertOutletRevenue(revenue);
          importedRows++;

          // Create journal entry for this revenue record
          jeCounter++;
          final jeId = _uuid.v4();
          final jeNumber = 'JE-CSV-${DateFormat('yyyyMMdd').format(date)}-${jeCounter.toString().padLeft(4, '0')}';

          journalEntries.add(JournalEntry(
            id: jeId,
            entryNumber: jeNumber,
            date: date,
            description: '${outlet.name} (${outlet.outletCode}) - Daily GGR',
            reference: 'CSV-$csvOutletCode-${DateFormat('yyyyMMdd').format(date)}',
            status: JournalEntryStatus.posted,
            lines: [
              // DR: Accounts Receivable (150) — GGR the outlet owes MagicBet
              JournalLine(id: '${jeId}-1', journalEntryId: jeId, accountId: 'acct-150', accountCode: '150', accountName: 'Accounts Receivable', debit: totalGGR, credit: 0),
              // DR: Payouts — contra-revenue for customer winnings paid
              JournalLine(id: '${jeId}-2', journalEntryId: jeId, accountId: 'acct-107', accountCode: '107', accountName: 'Payouts', debit: totalOut, credit: 0),
              // CR: Stakes — gross revenue recognised
              // Balance: DR(totalGGR + totalOut) = DR(totalIn) = CR(totalIn) ✓
              JournalLine(id: '${jeId}-3', journalEntryId: jeId, accountId: 'acct-103', accountCode: '103', accountName: 'Stakes', debit: 0, credit: totalIn),
            ],
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            createdBy: 'CSV Import',
          ));

          // Update progress
          state = state.copyWith(progress: i / totalRows);

        } catch (e) {
          errors.add('Row ${i + 1}: $e');
          skippedRows++;
        }
      }

      // Save journal entries to local storage
      if (journalEntries.isNotEmpty) {
        try {
          final existingEntries = await _localStorage.loadJournalEntries();
          var allEntries = [...existingEntries, ...journalEntries];
          journalEntriesCreated = journalEntries.length;

          // Create weekly commission JEs for any periods not yet covered.
          // Gaming tax JEs are NOT auto-generated (accountant enters manually).
          final ancillaryJEs = await _createAncillaryJEs(allEntries);
          if (ancillaryJEs.isNotEmpty) {
            allEntries = [...allEntries, ...ancillaryJEs];
            journalEntriesCreated += ancillaryJEs.length;

            // Queue commission + gaming-tax JEs for backend GL sync.
            // Daily revenue JEs are local-only (too many to queue individually).
            for (final je in ancillaryJEs) {
              _ref.read(syncServiceProvider.notifier).queueChange(
                action: SyncAction.create,
                entityType: SyncEntityType.journalEntry,
                entityId: je.id,
                data: je.toJson(),
              );
            }
          }

          await _localStorage.saveJournalEntries(allEntries);

          // Update the journals provider state
          _ref.read(journalsProvider.notifier).state = JournalsState(
            entries: allEntries,
            isLoading: false,
          );
        } catch (e) {
          errors.add('Failed to save journal entries: $e');
        }
      }

      // Refresh all revenue-dependent providers
      _ref.invalidate(dashboardDataProvider);
      _ref.invalidate(outletRevenueSummaryProvider);
      _ref.invalidate(outletAnalyticsProvider);

    } catch (e) {
      state = state.copyWith(isImporting: false, error: e.toString());
      return CsvImportResult(
        totalRows: totalRows,
        importedRows: importedRows,
        skippedRows: skippedRows,
        journalEntriesCreated: journalEntriesCreated,
        errors: [e.toString()],
      );
    }

    final result = CsvImportResult(
      totalRows: totalRows,
      importedRows: importedRows,
      skippedRows: skippedRows,
      journalEntriesCreated: journalEntriesCreated,
      errors: errors,
    );

    state = state.copyWith(
      isImporting: false,
      lastResult: result,
      progress: 1.0,
    );

    return result;
  }

  // ---------------------------------------------------------------------------
  // Public: Create / repair JEs for all outlet revenue records in the DB
  // ---------------------------------------------------------------------------
  // Safe to call after every CSV import (idempotent — uses the OutletRevenue's
  // [reference] field as the JE idempotency key so no duplicates are created).
  //
  // Creates:
  //   • One daily revenue JE per OutletRevenue row not already journalised
  //       DR  150 Accounts Receivable = GGR (outlet owes MagicBet this amount)
  //       DR  107 Payouts             = customer winnings paid out (contra-rev)
  //       CR  103 Stakes              = gross stakes wagered (full revenue)
  //   • Weekly commission JEs via _createAncillaryJEs()
  //       DR  178 Commission Expense  = 40% of carry-forward GGR
  //       CR  150 Accounts Receivable = reduces what outlet owes MagicBet
  //   Gaming tax JEs are NOT created automatically (accountant posts manually).
  // ---------------------------------------------------------------------------

  Future<List<String>> createJEsForOutletRevenues() async {
    final allRevenues = await _db.getAllOutletRevenues();
    if (allRevenues.isEmpty) return [];

    // Build outlet lookup map
    final outlets = await _db.getAllOutlets();
    final outletMap = <String, Outlet>{};
    for (final o in outlets) {
      outletMap[o.id] = o;
    }

    // Load existing JEs and collect their references (idempotency keys)
    final existingEntries = await _localStorage.loadJournalEntries();
    final existingRefs = existingEntries
        .map((e) => e.reference)
        .whereType<String>()
        .toSet();

    final newDailyJEs = <JournalEntry>[];
    final now = DateTime.now();
    int counter = 0;

    for (final rev in allRevenues) {
      // Use the revenue's own reference as the JE key (e.g. CSV-3000-20260101)
      final ref = rev.reference ??
          'CSV-${rev.outletId}-${DateFormat('yyyyMMdd').format(rev.date)}';
      if (existingRefs.contains(ref)) continue; // already journalised

      counter++;
      final jeId = _uuid.v4();
      final outletName = outletMap[rev.outletId]?.name ?? 'Outlet';

      // Arithmetic check:
      //   Total In (stakes) = GGR (netAmount) + Payouts (commissionAmount)
      //   DR side: netAmount + commissionAmount == CR side: amount  ✓
      newDailyJEs.add(JournalEntry(
        id: jeId,
        entryNumber:
            'REV-${DateFormat('yyyyMMdd').format(rev.date)}-${counter.toString().padLeft(4, '0')}',
        date: rev.date,
        description: '$outletName — Daily Revenue',
        reference: ref,
        status: JournalEntryStatus.posted,
        lines: [
          // DR: Accounts Receivable (150) — GGR the outlet owes MagicBet
          // (outlet holds cash; this is the net amount due after payouts)
          JournalLine(
            id: '$jeId-1',
            journalEntryId: jeId,
            accountId: 'acct-150',
            accountCode: '150',
            accountName: 'Accounts Receivable',
            debit: rev.netAmount,
            credit: 0,
          ),
          // DR: Payouts (107) — contra-revenue for winnings returned to players
          JournalLine(
            id: '$jeId-2',
            journalEntryId: jeId,
            accountId: 'acct-107',
            accountCode: '107',
            accountName: 'Payouts',
            debit: rev.commissionAmount,
            credit: 0,
          ),
          // CR: Stakes (103) — gross revenue recognised on all wagers placed
          JournalLine(
            id: '$jeId-3',
            journalEntryId: jeId,
            accountId: 'acct-103',
            accountCode: '103',
            accountName: 'Stakes',
            debit: 0,
            credit: rev.amount,
          ),
        ],
        createdAt: now,
        updatedAt: now,
        createdBy: 'System',
      ));
      existingRefs.add(ref);
    }

    // Build ancillary JEs (weekly commission + monthly gaming tax)
    final allCurrent = [...existingEntries, ...newDailyJEs];
    final ancillary = await _createAncillaryJEs(allCurrent);

    if (newDailyJEs.isNotEmpty || ancillary.isNotEmpty) {
      final allEntries = [...allCurrent, ...ancillary];
      await _localStorage.saveJournalEntries(allEntries);
      // Reload journals provider so CoA balances and reports update immediately
      await _ref.read(journalsProvider.notifier).loadJournals();
      _ref.invalidate(dashboardDataProvider);
      _ref.invalidate(outletRevenueSummaryProvider);
      _ref.invalidate(outletAnalyticsProvider);
    }

    // Return only the daily JE IDs created in this call (not commission JEs)
    return newDailyJEs.map((je) => je.id).toList();
  }

  // ---------------------------------------------------------------------------
  // Delete an outlet CSV upload and fully reverse everything it created
  // ---------------------------------------------------------------------------

  Future<void> deleteOutletCsvUpload(LocalOutletCsvUpload upload) async {
    // 1. Delete SQLite revenue rows
    await _db.deleteOutletRevenuesByIds(upload.revenueIds);

    // 2. Remove daily JEs + ALL commission JEs from JSON store.
    //    Commission JEs are global aggregates; we delete them all and
    //    regenerate from remaining revenue data in step 4.
    final allJournals = await _localStorage.loadJournalEntries();
    final dailyJeIdSet = upload.dailyJeIds.toSet();
    final remaining = allJournals.where((je) {
      if (dailyJeIdSet.contains(je.id)) return false;
      if (je.reference?.startsWith('JE-COMM-') == true) return false;
      return true;
    }).toList();
    await _localStorage.saveJournalEntries(remaining);
    await _ref.read(journalsProvider.notifier).loadJournals();

    // 3. Remove upload record
    await _ref.read(localOutletCsvUploadsProvider.notifier).remove(upload.id);

    // 4. Regenerate commission JEs from the now-smaller revenue dataset
    await createJEsForOutletRevenues();

    // 5. Invalidate UI providers
    _ref.invalidate(allOutletRevenuesProvider);
    _ref.invalidate(allOutletExpendituresProvider);
    _ref.invalidate(outletRevenueSummaryProvider);
    _ref.invalidate(outletAnalyticsProvider);
    _ref.invalidate(dashboardDataProvider);
  }

  // ---------------------------------------------------------------------------
  // Ancillary JEs — weekly outlet commission only
  // ---------------------------------------------------------------------------
  // Creates weekly commission JEs per outlet using the carry-forward GGR
  // algorithm. Gaming tax JEs are NOT auto-generated — the accountant posts
  // those manually so the correct figures and period allocations are applied.
  // Reference codes are idempotency keys; re-imports never double-post.
  // ---------------------------------------------------------------------------

  Future<List<JournalEntry>> _createAncillaryJEs(
    List<JournalEntry> existingEntries,
  ) async {
    final existingRefs = existingEntries
        .map((e) => e.reference)
        .whereType<String>()
        .toSet();
    final result = <JournalEntry>[];
    final now = DateTime.now();

    final outlets = await _db.getAllOutlets();
    final allRevenues = await _db.getAllOutletRevenues();
    if (outlets.isEmpty || allRevenues.isEmpty) return result;

    // ── 1. Weekly outlet commission JEs (per outlet) ─────────────────────────
    final revenuesByOutlet = <String, List<OutletRevenue>>{};
    for (final rev in allRevenues) {
      revenuesByOutlet.putIfAbsent(rev.outletId, () => []).add(rev);
    }

    for (final outlet in outlets) {
      final revs = revenuesByOutlet[outlet.id] ?? [];
      final weeks = _computeWeeksForOutlet(outlet, revs);

      for (final week in weeks) {
        if (week.outletExpense <= 0) continue;

        final ref =
            'JE-COMM-${outlet.outletCode}-${week.year}-W${week.weekNumber.toString().padLeft(2, '0')}';
        if (existingRefs.contains(ref)) continue;

        final jeId = _uuid.v4();
        final weekLabel = 'Week ${week.weekNumber} ${week.year}';
        result.add(JournalEntry(
          id: jeId,
          entryNumber: ref,
          date: week.weekEnd,
          description:
              'Outlet Commission (40% GGR) — ${outlet.name} — $weekLabel',
          reference: ref,
          status: JournalEntryStatus.posted,
          lines: [
            // DR: Outlet Commission Expense (178)
            JournalLine(
              id: '$jeId-1', journalEntryId: jeId,
              accountId: 'acct-178', accountCode: '178',
              accountName: 'Outlet Commission Expense',
              debit: week.outletExpense, credit: 0,
            ),
            // CR: Accounts Receivable (150) — commission reduces what the outlet
            // owes MagicBet; net AR balance = GGR less commission due to owner
            JournalLine(
              id: '$jeId-2', journalEntryId: jeId,
              accountId: 'acct-150', accountCode: '150',
              accountName: 'Accounts Receivable',
              debit: 0, credit: week.outletExpense,
            ),
          ],
          createdAt: now,
          updatedAt: now,
          createdBy: 'System',
        ));
        existingRefs.add(ref);
      }
    }

    // Gaming tax JEs are NOT auto-generated — the accountant posts those
    // manually so the correct figures and period allocations are applied.

    return result;
  }

  /// Parse a CSV line handling quoted fields with commas
  List<String> _parseCsvLine(String line) {
    final fields = <String>[];
    var current = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        fields.add(current.toString());
        current = StringBuffer();
      } else {
        current.write(char);
      }
    }
    fields.add(current.toString());

    return fields;
  }
}

final csvImportProvider = StateNotifierProvider<CsvImportNotifier, CsvImportState>((ref) {
  final db = ref.read(databaseProvider);
  return CsvImportNotifier(db, ref);
});

// ============================================================================
// Outlet Revenue Aggregation Providers
// ============================================================================

/// All outlet revenues stream
final allOutletRevenuesProvider = StreamProvider<List<OutletRevenue>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.outletRevenues).watch();
});

/// Stream provider for all outlet expenditures
final allOutletExpendituresProvider = StreamProvider<List<OutletExpenditure>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.outletExpenditures).watch();
});

/// Revenue summary per outlet
final outletRevenueSummaryProvider = FutureProvider<Map<String, Map<String, double>>>((ref) async {
  final db = ref.read(databaseProvider);
  final revenues = await db.getAllOutletRevenues();
  final outlets = await db.getAllOutlets();

  final summary = <String, Map<String, double>>{};

  for (final outlet in outlets) {
    final outletRevs = revenues.where((r) => r.outletId == outlet.id);
    double totalIn = 0, totalOut = 0, totalGGR = 0;
    for (final rev in outletRevs) {
      totalIn += rev.amount;
      totalOut += rev.commissionAmount;
      totalGGR += rev.netAmount;
    }
    summary[outlet.outletCode] = {
      'totalIn': totalIn,
      'totalOut': totalOut,
      'totalGGR': totalGGR,
      'days': outletRevs.length.toDouble(),
    };
  }

  return summary;
});

// ============================================================================
// Outlet Analytics — Carry-Forward Commission Engine
// ============================================================================
//
// Business Rules (MagicBet):
//  • Revenue data arrives weekly per outlet.
//  • 40% of GGR is the outlet expense (commission to location owner).
//  • If a week's adjusted GGR ≤ 0  → NO 40% deducted; full negative carried forward.
//  • If a week's adjusted GGR  > 0  → 40% deducted on the adjusted GGR.
//  • "Adjusted GGR" = raw week GGR + carriedForward (negative from prior week).
//  • Net Revenue = adjusted GGR × 60% (what MagicBet actually keeps).
//
// Example:
//   Week 1: rawGGR = -20 000 → adjustedGGR = -20 000 → no expense → carry -20 000
//   Week 2: rawGGR = 80 000  → adjustedGGR = 60 000  → expense = 24 000 → net = 36 000

class OutletWeekSummary {
  final String outletId;
  final String outletName;
  final String outletCode;
  final DateTime weekStart;   // Monday of the week
  final DateTime weekEnd;     // Sunday of the week
  final int weekNumber;
  final int year;
  final double rawGGR;
  final double carriedForward; // negative from previous week (≤ 0)
  final double adjustedGGR;
  final double outletExpense;  // 40% if adjustedGGR > 0, else 0
  final double netRevenue;     // what MagicBet keeps

  const OutletWeekSummary({
    required this.outletId,
    required this.outletName,
    required this.outletCode,
    required this.weekStart,
    required this.weekEnd,
    required this.weekNumber,
    required this.year,
    required this.rawGGR,
    required this.carriedForward,
    required this.adjustedGGR,
    required this.outletExpense,
    required this.netRevenue,
  });
}

class OutletMonthSummary {
  final String outletId;
  final String outletName;
  final String outletCode;
  final int year;
  final int month;
  final double totalGGR;
  final double totalOutletExpense;
  final double netRevenue;

  const OutletMonthSummary({
    required this.outletId,
    required this.outletName,
    required this.outletCode,
    required this.year,
    required this.month,
    required this.totalGGR,
    required this.totalOutletExpense,
    required this.netRevenue,
  });
}

class OutletAnalyticsData {
  final double totalGGR;
  final double totalOutletExpense;
  final double totalNetRevenue;
  final int totalActiveOutlets;
  final List<OutletWeekSummary> allWeeks;   // all outlets × all weeks
  final List<OutletMonthSummary> allMonths; // all outlets × all months
  // Per-outlet lifetime totals
  final List<OutletLifetime> lifetimeTotals;

  const OutletAnalyticsData({
    required this.totalGGR,
    required this.totalOutletExpense,
    required this.totalNetRevenue,
    required this.totalActiveOutlets,
    required this.allWeeks,
    required this.allMonths,
    required this.lifetimeTotals,
  });

  static const empty = OutletAnalyticsData(
    totalGGR: 0,
    totalOutletExpense: 0,
    totalNetRevenue: 0,
    totalActiveOutlets: 0,
    allWeeks: [],
    allMonths: [],
    lifetimeTotals: [],
  );
}

class OutletLifetime {
  final String outletId;
  final String outletName;
  final String outletCode;
  final double totalGGR;
  final double totalOutletExpense;
  final double netRevenue;

  const OutletLifetime({
    required this.outletId,
    required this.outletName,
    required this.outletCode,
    required this.totalGGR,
    required this.totalOutletExpense,
    required this.netRevenue,
  });
}

// Returns the Monday (start) of the ISO week containing [date].
DateTime _weekStart(DateTime date) {
  final diff = date.weekday - DateTime.monday;
  return DateTime(date.year, date.month, date.day - diff);
}

// Key for grouping: "yyyy-Www" e.g. "2025-W12"
String _weekKey(DateTime date) {
  final start = _weekStart(date);
  // ISO week number: days from Jan 4 of year (first week always contains Jan 4)
  final jan4 = DateTime(start.year, 1, 4);
  final weekNum = ((start.difference(jan4).inDays + jan4.weekday) / 7).ceil();
  return '${start.year}-W${weekNum.toString().padLeft(2, '0')}';
}

int _isoWeekNumber(DateTime date) {
  final start = _weekStart(date);
  final jan4 = DateTime(start.year, 1, 4);
  return ((start.difference(jan4).inDays + jan4.weekday) / 7).ceil();
}

List<OutletWeekSummary> _computeWeeksForOutlet(
  Outlet outlet,
  List<OutletRevenue> revenues,
) {
  if (revenues.isEmpty) return [];

  // Group raw GGR by ISO week
  final weekRaw = <String, double>{};
  final weekStartDates = <String, DateTime>{};

  for (final rev in revenues) {
    final key = _weekKey(rev.date);
    weekRaw[key] = (weekRaw[key] ?? 0) + rev.netAmount;
    final ws = _weekStart(rev.date);
    if (!weekStartDates.containsKey(key) || ws.isBefore(weekStartDates[key]!)) {
      weekStartDates[key] = ws;
    }
  }

  // Sort weeks chronologically
  final sortedKeys = weekRaw.keys.toList()..sort();

  final summaries = <OutletWeekSummary>[];
  double carriedForward = 0; // negative balance carried from previous week

  for (final key in sortedKeys) {
    final rawGGR = weekRaw[key]!;
    final ws = weekStartDates[key]!;
    final incomingCarry = carriedForward; // capture before update
    final adjustedGGR = rawGGR + incomingCarry;
    final double outletExpense;
    final double netRevenue;

    if (adjustedGGR > 0) {
      outletExpense = adjustedGGR * 0.40;
      netRevenue = adjustedGGR * 0.60;
      carriedForward = 0;
    } else {
      outletExpense = 0;
      netRevenue = adjustedGGR;
      carriedForward = adjustedGGR;
    }

    summaries.add(OutletWeekSummary(
      outletId: outlet.id,
      outletName: outlet.name,
      outletCode: outlet.outletCode,
      weekStart: ws,
      weekEnd: ws.add(const Duration(days: 6)),
      weekNumber: _isoWeekNumber(ws),
      year: ws.year,
      rawGGR: rawGGR,
      carriedForward: incomingCarry, // what came in from previous week
      adjustedGGR: adjustedGGR,
      outletExpense: outletExpense,
      netRevenue: netRevenue,
    ));
  }

  return summaries;
}

final outletAnalyticsProvider = FutureProvider<OutletAnalyticsData>((ref) async {
  final db = ref.read(databaseProvider);
  final outlets = await db.getAllOutlets();
  final allRevenues = await db.getAllOutletRevenues();

  if (outlets.isEmpty || allRevenues.isEmpty) return OutletAnalyticsData.empty;

  final revenuesByOutlet = <String, List<OutletRevenue>>{};
  for (final rev in allRevenues) {
    revenuesByOutlet.putIfAbsent(rev.outletId, () => []).add(rev);
  }

  final allWeeks = <OutletWeekSummary>[];
  final allMonths = <OutletMonthSummary>[];
  final lifetimes = <OutletLifetime>[];

  for (final outlet in outlets) {
    final revs = revenuesByOutlet[outlet.id] ?? [];
    final weeks = _computeWeeksForOutlet(outlet, revs);
    allWeeks.addAll(weeks);

    // Aggregate months from weekly summaries (use adjustedGGR and outletExpense)
    // Group weeks into months by weekStart month
    final monthMap = <String, _MonthAccum>{};
    for (final w in weeks) {
      final mk = '${w.year}-${w.weekStart.month.toString().padLeft(2, '0')}';
      monthMap.putIfAbsent(mk, () => _MonthAccum(w.weekStart.year, w.weekStart.month));
      monthMap[mk]!.addWeek(w);
    }
    for (final accum in monthMap.values) {
      allMonths.add(OutletMonthSummary(
        outletId: outlet.id,
        outletName: outlet.name,
        outletCode: outlet.outletCode,
        year: accum.year,
        month: accum.month,
        totalGGR: accum.totalGGR,
        totalOutletExpense: accum.totalOutletExpense,
        netRevenue: accum.netRevenue,
      ));
    }

    // Lifetime totals per outlet
    final lifetimeGGR = weeks.fold(0.0, (s, w) => s + w.rawGGR);
    final lifetimeExpense = weeks.fold(0.0, (s, w) => s + w.outletExpense);
    final lifetimeNet = weeks.fold(0.0, (s, w) => s + w.netRevenue);
    lifetimes.add(OutletLifetime(
      outletId: outlet.id,
      outletName: outlet.name,
      outletCode: outlet.outletCode,
      totalGGR: lifetimeGGR,
      totalOutletExpense: lifetimeExpense,
      netRevenue: lifetimeNet,
    ));
  }

  final grandGGR = lifetimes.fold(0.0, (s, o) => s + o.totalGGR);
  final grandExpense = lifetimes.fold(0.0, (s, o) => s + o.totalOutletExpense);
  final grandNet = lifetimes.fold(0.0, (s, o) => s + o.netRevenue);

  return OutletAnalyticsData(
    totalGGR: grandGGR,
    totalOutletExpense: grandExpense,
    totalNetRevenue: grandNet,
    totalActiveOutlets: outlets.where((o) => o.isActive).length,
    allWeeks: allWeeks,
    allMonths: allMonths,
    lifetimeTotals: lifetimes,
  );
});

class _MonthAccum {
  final int year;
  final int month;
  double totalGGR = 0;
  double totalOutletExpense = 0;
  double netRevenue = 0;
  _MonthAccum(this.year, this.month);
  void addWeek(OutletWeekSummary w) {
    totalGGR += w.rawGGR;
    totalOutletExpense += w.outletExpense;
    netRevenue += w.netRevenue;
  }
}
