import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../core/theme/app_theme.dart';
import '../core/services/auth_service.dart';
import '../core/services/server_sync_service.dart';
import '../core/services/data_service.dart' show databaseProvider, journalsProvider, JournalsState;
import '../core/providers/sync_status_provider.dart';
import '../features/settings/settings_screen.dart' show reloadEverythingAfterRestore;

class AppShell extends ConsumerStatefulWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _isCollapsed = false;

  @override
  void initState() {
    super.initState();
    // Ensure the SyncStatusNotifier is alive for the whole shell lifetime.
    Future.microtask(() {
      if (!mounted) return;
      ref.read(syncStatusProvider); // warm up
      // Listen for initial-restore prompt after first build.
      ref.listenManual<SyncStatusState>(syncStatusProvider, (prev, next) {
        if (next.needsInitialRestore && !(prev?.needsInitialRestore ?? false)) {
          _showRestorePrompt();
        }
      });
      // The journals file can exist with real content but still fail to
      // load (a write interrupted before saves became atomic — see
      // local_storage_service.dart). That machine has real local data, so
      // it must never be silently offered a stale server restore over it
      // — but it also can't just look like an empty, working app with no
      // explanation. Surface it plainly instead.
      ref.listenManual<JournalsState>(journalsProvider, (prev, next) {
        if (next.loadFailed && !(prev?.loadFailed ?? false)) {
          _showLoadFailedWarning();
        }
      });
    });
  }

  Future<void> _showLoadFailedWarning() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠ Local data could not be read'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'A journals file exists on this machine with real data in it, but it '
            'could not be loaded — most likely it was left partially written by an '
            'interrupted save (a crash, a forced close, a power cut).\n\n'
            'The unreadable file has been preserved (a ".unreadable-…bak" copy next '
            'to it) so nothing was overwritten or lost. Do NOT restore from the '
            'server from this screen — that backup may be older than what\'s in this '
            'file. Use Settings → "Diagnose & Refresh Local Data", or send the '
            'preserved file to support, before continuing.',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('I understand'),
          ),
        ],
      ),
    );
  }

  /// A machine with no local data (fresh install, new device, reset
  /// profile) has nothing to lose from restoring automatically — unlike a
  /// machine with a corrupted-but-present file (which sync_status_provider
  /// already excludes from this path; see its comment). So this no longer
  /// blocks on a "Restore?" click — it just does it, since making someone
  /// click a button doesn't make the restore any safer. What DOES matter,
  /// and what a modal doesn't guarantee gets read either, is knowing how
  /// OLD the restored data is: this server only ever holds what the last
  /// successful sync sent it, which a real incident showed can silently
  /// go weeks or months stale. So the one thing this flow is strict about
  /// is making the backup's age impossible to miss afterward.
  Future<void> _showRestorePrompt() async {
    if (!mounted) return;
    final preview = await ServerSyncService.previewLatestBackup();
    if (!mounted) return;

    ref.read(syncStatusProvider.notifier).dismissRestorePrompt();

    if (preview == null) {
      // Nothing on the server either — genuinely a brand new setup, nothing
      // to restore. Let the normal empty-state UI take over.
      return;
    }

    await _runServerRestore(preview);
  }

  Future<void> _runServerRestore(ServerBackupPreview preview) async {
    final messenger = ScaffoldMessenger.of(context);
    final syncedAt = DateTime.tryParse(preview.syncedAt ?? '');
    final ageDays = syncedAt != null ? DateTime.now().difference(syncedAt).inDays : null;

    messenger.showSnackBar(SnackBar(
      content: const Text('No local data found — loading your last backup from the server…'),
      duration: const Duration(seconds: 3),
    ));

    final db = ref.read(databaseProvider);
    final result = await ServerSyncService.pullAndRestore(db);
    // Files on disk are now correct, but the already-running app's
    // providers won't know that on their own — reload them so the UI
    // reflects the restore immediately instead of needing a full restart.
    if (result.success) await reloadEverythingAfterRestore(ref.read, ref.invalidate);
    if (!mounted) return;

    if (!result.success) {
      messenger.showSnackBar(SnackBar(
        content: Text('Restore failed: ${result.error}'),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 6),
      ));
      return;
    }

    final dateLabel = syncedAt != null
        ? DateFormat('d MMM yyyy, HH:mm').format(syncedAt.toLocal())
        : (preview.syncedAt ?? 'unknown date');

    // A same-day (or missing-date) backup is unremarkable — a plain
    // confirmation is enough. Anything older gets a loud, stays-on-screen-
    // until-dismissed warning instead of a snackbar that vanishes in a few
    // seconds, because the consequence of not noticing is working an
    // entire session on books that are missing however many days of real
    // activity happened since.
    if (ageDays == null || ageDays < 1) {
      messenger.showSnackBar(SnackBar(
        content: Text('Restore complete — data loaded from server backup ($dateLabel).'),
        backgroundColor: AppColors.success,
        duration: const Duration(seconds: 4),
      ));
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠ Restored backup is out of date'),
        content: SizedBox(
          width: 420,
          child: Text(
            'No local data was found on this machine, so it was restored from the '
            'last backup the server has: $dateLabel — that\'s $ageDays day${ageDays == 1 ? '' : 's'} old.\n\n'
            'Anything entered after that date is NOT in this restore. Check with the '
            'team about what may be missing before relying on these figures.',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('I understand'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final user = authState.user;

    return Scaffold(
      body: Column(
        children: [
          // Top navigation bar
          _buildTopBar(context),

          // Main content
          Expanded(
            child: Row(
              children: [
                // Sidebar
                _buildSidebar(context, user),

                // Main content area
                Expanded(
                  child: Container(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: widget.child,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      height: 48,
      color: AppColors.sidebarBackground,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Image.asset(
            'assets/images/logo_white.png',
            height: 22,
            errorBuilder: (_, __, ___) => const Icon(
              Icons.account_balance,
              color: AppColors.secondary,
              size: 22,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'MagicBet Accounting',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: 0.3,
            ),
          ),
          const Spacer(),
          // Sync status badge
          _SyncStatusBadge(),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context, User? user) {
    final currentPath = GoRouterState.of(context).uri.path;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: _isCollapsed ? 70 : 260,
      color: AppColors.sidebarBackground,
      child: Column(
        children: [
          // User profile section
          if (!_isCollapsed)
            _buildUserSection(user),

          const Divider(color: AppColors.sidebarItemHover, height: 1),

          // Navigation items
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _buildNavSection('MAIN'),
                _buildNavItem(
                  context,
                  icon: Icons.dashboard_outlined,
                  activeIcon: Icons.dashboard,
                  label: 'Dashboard',
                  path: '/',
                  isActive: currentPath == '/',
                ),

                const SizedBox(height: 16),
                _buildNavSection('OUTLETS'),
                _buildNavItem(
                  context,
                  icon: Icons.store_mall_directory_outlined,
                  activeIcon: Icons.store_mall_directory,
                  label: 'Outlets',
                  path: '/outlets',
                  isActive: currentPath == '/outlets',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.attach_money_outlined,
                  activeIcon: Icons.attach_money,
                  label: 'Revenue',
                  path: '/outlet-revenue',
                  isActive: currentPath == '/outlet-revenue',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.analytics_outlined,
                  activeIcon: Icons.analytics,
                  label: 'Analytics',
                  path: '/outlet-analytics',
                  isActive: currentPath == '/outlet-analytics',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.money_off_outlined,
                  activeIcon: Icons.money_off,
                  label: 'Expenditures',
                  path: '/outlet-expenditure',
                  isActive: currentPath == '/outlet-expenditure',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.cloud_upload_outlined,
                  activeIcon: Icons.cloud_upload,
                  label: 'Upload Data',
                  path: '/outlet-upload',
                  isActive: currentPath == '/outlet-upload',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.handshake_outlined,
                  activeIcon: Icons.handshake,
                  label: 'Settled',
                  path: '/outlet-settled',
                  isActive: currentPath == '/outlet-settled',
                ),

                const SizedBox(height: 16),
                _buildNavSection('ACCOUNTING'),
                _buildNavItem(
                  context,
                  icon: Icons.account_tree_outlined,
                  activeIcon: Icons.account_tree,
                  label: 'Chart of Accounts',
                  path: '/accounts',
                  isActive: currentPath == '/accounts',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.book_outlined,
                  activeIcon: Icons.book,
                  label: 'Journal Entries',
                  path: '/journals',
                  isActive: currentPath == '/journals',
                ),

                const SizedBox(height: 16),
                _buildNavSection('SALES'),
                _buildNavItem(
                  context,
                  icon: Icons.people_outline,
                  activeIcon: Icons.people,
                  label: 'Customers',
                  path: '/customers',
                  isActive: currentPath == '/customers',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.receipt_long_outlined,
                  activeIcon: Icons.receipt_long,
                  label: 'Invoices',
                  path: '/invoices',
                  isActive: currentPath == '/invoices',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.receipt_outlined,
                  activeIcon: Icons.receipt,
                  label: 'Credit/Debit Notes',
                  path: '/credit-notes',
                  isActive: currentPath == '/credit-notes',
                ),

                const SizedBox(height: 16),
                _buildNavSection('PURCHASES'),
                _buildNavItem(
                  context,
                  icon: Icons.store_outlined,
                  activeIcon: Icons.store,
                  label: 'Vendors',
                  path: '/vendors',
                  isActive: currentPath == '/vendors',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.description_outlined,
                  activeIcon: Icons.description,
                  label: 'Bills',
                  path: '/bills',
                  isActive: currentPath == '/bills',
                ),

                const SizedBox(height: 16),
                _buildNavSection('BANKING'),
                _buildNavItem(
                  context,
                  icon: Icons.account_balance_outlined,
                  activeIcon: Icons.account_balance,
                  label: 'Banks',
                  path: '/banking',
                  isActive: currentPath == '/banking',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.compare_arrows_outlined,
                  activeIcon: Icons.compare_arrows,
                  label: 'Reconciliation',
                  path: '/bank-reconciliation',
                  isActive: currentPath == '/bank-reconciliation',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.payments_outlined,
                  activeIcon: Icons.payments,
                  label: 'Payments',
                  path: '/payments',
                  isActive: currentPath == '/payments',
                ),

                const SizedBox(height: 16),
                _buildNavSection('ASSETS'),
                _buildNavItem(
                  context,
                  icon: Icons.inventory_2_outlined,
                  activeIcon: Icons.inventory_2,
                  label: 'Assets',
                  path: '/assets',
                  isActive: currentPath == '/assets',
                ),
                _buildNavItem(
                  context,
                  icon: Icons.trending_down_outlined,
                  activeIcon: Icons.trending_down,
                  label: 'Depreciation',
                  path: '/depreciation',
                  isActive: currentPath == '/depreciation',
                ),

                const SizedBox(height: 16),
                _buildNavSection('REPORTS'),
                _buildNavItem(
                  context,
                  icon: Icons.analytics_outlined,
                  activeIcon: Icons.analytics,
                  label: 'Reports',
                  path: '/reports',
                  isActive: currentPath == '/reports',
                ),
              ],
            ),
          ),

          // Bottom section
          const Divider(color: AppColors.sidebarItemHover, height: 1),

          _buildNavItem(
            context,
            icon: Icons.settings_outlined,
            activeIcon: Icons.settings,
            label: 'Settings',
            path: '/settings',
            isActive: GoRouterState.of(context).uri.path == '/settings',
          ),

          _buildLogoutButton(context),

          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: _isCollapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.spaceBetween,
              children: [
                if (!_isCollapsed)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      '© 2026 Magic Bet Ltd',
                      style: TextStyle(
                        color: AppColors.sidebarTextMuted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                IconButton(
                  onPressed: () => setState(() => _isCollapsed = !_isCollapsed),
                  icon: Icon(
                    _isCollapsed ? Icons.chevron_right : Icons.chevron_left,
                    color: AppColors.sidebarTextMuted,
                  ),
                  tooltip: _isCollapsed ? 'Expand' : 'Collapse',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserSection(User? user) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.secondary, AppColors.secondaryLight],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.secondary.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    user?.name.isNotEmpty == true
                        ? user!.name.substring(0, 1).toUpperCase()
                        : 'U',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user?.name ?? 'User',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      user?.email ?? '',
                      style: TextStyle(
                        color: AppColors.sidebarTextMuted,
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.secondary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.verified_user, size: 14, color: AppColors.secondary),
                const SizedBox(width: 6),
                Text(
                  user?.role.replaceAll('_', ' ').toUpperCase() ?? 'USER',
                  style: TextStyle(
                    color: AppColors.secondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogoutButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () => _showLogoutDialog(context),
          borderRadius: BorderRadius.circular(8),
          hoverColor: Colors.red.withOpacity(0.15),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            child: Row(
              mainAxisAlignment: _isCollapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Icon(Icons.logout, color: Colors.red.shade300, size: 20),
                if (!_isCollapsed) ...[
                  const SizedBox(width: 12),
                  Text(
                    'Sign Out',
                    style: TextStyle(
                      color: Colors.red.shade300,
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (ctx) => const Center(child: CircularProgressIndicator()),
              );
              await ref.read(authStateProvider.notifier).logout();
              if (mounted) {
                Navigator.pop(context);
                context.go('/login');
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
  }

  Widget _buildNavSection(String title) {
    if (_isCollapsed) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.sidebarTextMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context, {
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required String path,
    required bool isActive,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () => context.go(path),
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppColors.sidebarItemHover,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.sidebarItemActive.withOpacity(0.15)
                  : null,
              borderRadius: BorderRadius.circular(8),
              border: isActive
                  ? Border(
                      left: BorderSide(
                        color: AppColors.sidebarItemActive,
                        width: 3,
                      ),
                    )
                  : null,
            ),
            child: Row(
              mainAxisAlignment: _isCollapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Icon(
                  isActive ? activeIcon : icon,
                  color: isActive
                      ? AppColors.sidebarItemActive
                      : AppColors.sidebarText,
                  size: 20,
                ),
                if (!_isCollapsed) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: isActive
                            ? AppColors.sidebarItemActive
                            : AppColors.sidebarText,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w400,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Sync status badge shown in the top bar ────────────────────────────────────

class _SyncStatusBadge extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncStatusProvider);

    Color bg, fg;
    IconData icon;
    String label;
    String tooltip;

    if (sync.isSyncing) {
      bg = Colors.blue.withOpacity(0.15);
      fg = Colors.blue.shade200;
      icon = Icons.cloud_sync;
      label = 'Syncing…';
      tooltip = 'Backup push in progress';
    } else if (sync.syncError != null) {
      bg = AppColors.error.withOpacity(0.15);
      fg = Colors.red.shade300;
      icon = Icons.cloud_off;
      label = 'Sync error';
      tooltip = sync.syncError!;
    } else if (sync.isFresh) {
      bg = AppColors.income.withOpacity(0.15);
      fg = AppColors.income;
      icon = Icons.cloud_done;
      final dt = DateTime.tryParse(sync.lastSyncAt!);
      label = dt != null ? 'Synced ${DateFormat('HH:mm').format(dt)}' : 'Synced';
      tooltip = 'Last backup: ${dt != null ? DateFormat('d MMM yyyy, HH:mm').format(dt) : sync.lastSyncAt}';
    } else if (sync.isStale) {
      bg = Colors.orange.withOpacity(0.15);
      fg = Colors.orange.shade300;
      icon = Icons.cloud_upload_outlined;
      final dt = DateTime.tryParse(sync.lastSyncAt!);
      label = 'Stale backup';
      tooltip = 'Last backup: ${dt != null ? DateFormat('d MMM yyyy, HH:mm').format(dt) : sync.lastSyncAt}';
    } else {
      bg = Colors.grey.withOpacity(0.15);
      fg = Colors.grey.shade400;
      icon = Icons.cloud_off_outlined;
      label = 'Not synced';
      tooltip = 'No server backup yet. Configure in Settings.';
    }

    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: sync.isSyncing ? null : () => ref.read(syncStatusProvider.notifier).push(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              sync.isSyncing
                  ? SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5, color: fg))
                  : Icon(icon, size: 14, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
