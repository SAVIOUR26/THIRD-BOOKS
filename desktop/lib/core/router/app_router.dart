import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/splash/splash_screen.dart';
import '../../features/auth/login_screen.dart';
import '../../features/dashboard/dashboard_screen.dart';
import '../../features/accounts/accounts_screen.dart';
import '../../features/journals/journals_screen.dart';
import '../../features/customers/customers_screen.dart';
import '../../features/invoices/invoices_screen.dart';
import '../../features/vendors/vendors_screen.dart';
import '../../features/bills/bills_screen.dart';
import '../../features/payments/payments_screen.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/outlets/outlets_screen.dart';
import '../../features/outlets/outlet_revenue_screen.dart';
import '../../features/outlets/outlet_expenditure_screen.dart';
import '../../features/outlets/outlet_upload_screen.dart';
import '../../features/outlets/outlet_analytics_screen.dart';
import '../../features/banking/bank_reconciliation_screen.dart';
import '../../features/assets/assets_screen.dart';
import '../../features/assets/depreciation_screen.dart';
import '../../features/banking/banking_screen.dart';
import '../../features/outlets/outlet_settled_screen.dart';
import '../../features/notes/credit_debit_notes_screen.dart';
import '../../widgets/app_shell.dart';
import '../services/auth_service.dart';

// Exposed so code outside the widget tree (e.g. the window-close handler in
// main.dart, which needs to show a blocking "saving…" dialog before the
// native window is destroyed) can reach a valid BuildContext.
final rootNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/splash',
    debugLogDiagnostics: false,
    redirect: (context, state) {
      final isLoggedIn = authState.isAuthenticated;
      final isLoggingIn = state.matchedLocation == '/login';
      final isSplash = state.matchedLocation == '/splash';

      // Allow splash screen
      if (isSplash) return null;

      // If not logged in and not on login page, redirect to login
      if (!isLoggedIn && !isLoggingIn) {
        return '/login';
      }

      // If logged in and on login page, redirect to home
      if (isLoggedIn && isLoggingIn) {
        return '/';
      }

      return null;
    },
    routes: [
      // Splash screen
      GoRoute(
        path: '/splash',
        name: 'splash',
        builder: (context, state) => const SplashScreen(),
      ),

      // Auth routes
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),

      // Main app shell with sidebar navigation
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/',
            name: 'dashboard',
            builder: (context, state) => const DashboardScreen(),
          ),
          GoRoute(
            path: '/accounts',
            name: 'accounts',
            builder: (context, state) => const AccountsScreen(),
          ),
          GoRoute(
            path: '/journals',
            name: 'journals',
            builder: (context, state) => const JournalsScreen(),
          ),
          GoRoute(
            path: '/customers',
            name: 'customers',
            builder: (context, state) => const CustomersScreen(),
          ),
          GoRoute(
            path: '/invoices',
            name: 'invoices',
            builder: (context, state) => const InvoicesScreen(),
          ),
          GoRoute(
            path: '/vendors',
            name: 'vendors',
            builder: (context, state) => const VendorsScreen(),
          ),
          GoRoute(
            path: '/bills',
            name: 'bills',
            builder: (context, state) => const BillsScreen(),
          ),
          GoRoute(
            path: '/payments',
            name: 'payments',
            builder: (context, state) => const PaymentsScreen(),
          ),
          GoRoute(
            path: '/banking',
            name: 'banking',
            builder: (context, state) => const BankingScreen(),
          ),
          GoRoute(
            path: '/bank-reconciliation',
            name: 'bank-reconciliation',
            builder: (context, state) => const BankReconciliationScreen(),
          ),
          GoRoute(
            path: '/reports',
            name: 'reports',
            builder: (context, state) => const ReportsScreen(),
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            builder: (context, state) => const SettingsScreen(),
          ),

          // MAGIC BET - Outlet Management Routes
          GoRoute(
            path: '/outlets',
            name: 'outlets',
            builder: (context, state) => const OutletsScreen(),
          ),
          GoRoute(
            path: '/outlet-revenue',
            name: 'outlet-revenue',
            builder: (context, state) {
              final outletId = state.uri.queryParameters['outletId'];
              final outletName = state.uri.queryParameters['outletName'];
              return OutletRevenueScreen(
                outletId: outletId,
                outletName: outletName,
              );
            },
          ),
          GoRoute(
            path: '/outlet-expenditure',
            name: 'outlet-expenditure',
            builder: (context, state) {
              final outletId = state.uri.queryParameters['outletId'];
              final outletName = state.uri.queryParameters['outletName'];
              return OutletExpenditureScreen(
                outletId: outletId,
                outletName: outletName,
              );
            },
          ),
          GoRoute(
            path: '/outlet-upload',
            name: 'outlet-upload',
            builder: (context, state) => const OutletUploadScreen(),
          ),
          GoRoute(
            path: '/outlet-analytics',
            name: 'outlet-analytics',
            builder: (context, state) => const OutletAnalyticsScreen(),
          ),
          GoRoute(
            path: '/outlet-settled',
            name: 'outlet-settled',
            builder: (context, state) => const OutletSettledScreen(),
          ),
          GoRoute(
            path: '/credit-notes',
            name: 'credit-notes',
            builder: (context, state) => const CreditDebitNotesScreen(),
          ),

          // MAGIC BET - Asset Management Routes
          GoRoute(
            path: '/assets',
            name: 'assets',
            builder: (context, state) => const AssetsScreen(),
          ),
          GoRoute(
            path: '/depreciation',
            name: 'depreciation',
            builder: (context, state) => const DepreciationScreen(),
          ),
        ],
      ),
    ],
  );
});
