import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'core/theme/app_theme.dart';
import 'core/router/app_router.dart';
import 'core/services/theme_service.dart';
import 'core/services/server_sync_service.dart';
import 'core/services/data_service.dart' show databaseProvider;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Intercept the window close button so we can attempt one last backup
  // push before the app actually exits — otherwise a short session (open,
  // enter a few entries, close) can end before the login-time push or the
  // periodic timer ever gets a chance to run, and that session's data is
  // never backed up.
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);

  runApp(
    const ProviderScope(
      child: ThirdBooksApp(),
    ),
  );
}

class ThirdBooksApp extends ConsumerStatefulWidget {
  const ThirdBooksApp({super.key});

  @override
  ConsumerState<ThirdBooksApp> createState() => _ThirdBooksAppState();
}

class _ThirdBooksAppState extends ConsumerState<ThirdBooksApp> with WindowListener {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;

    // A real backup is routinely 19-20MB and, per ServerSyncService, can
    // legitimately take up to 4 minutes to upload on a slow connection.
    // The previous 8-second cap here was nowhere near that — it silently
    // aborted the close-time push on every single close for any real
    // dataset, so this "last chance to back up" never actually completed.
    // Combined with short-lived sessions (open, do a task, close), that
    // meant the app could go weeks looking "Online" (the tiny heartbeat
    // always succeeds) while the real backup never got through. Give this
    // the same ceiling pushBackup() itself uses, and tell the user why the
    // window hasn't closed yet instead of leaving it looking frozen.
    final navContext = rootNavigatorKey.currentContext;
    var dialogShown = false;
    if (navContext != null) {
      dialogShown = true;
      showDialog(
        context: navContext,
        barrierDismissible: false,
        builder: (_) => const PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                SizedBox(width: 16),
                Expanded(child: Text('Saving your work before closing…')),
              ],
            ),
          ),
        ),
      );
    }

    try {
      // Reuse the app's shared database connection rather than opening a
      // fresh, never-closed one — see sync_status_provider.dart for why.
      await ServerSyncService.pushBackup(ref.read(databaseProvider))
          .timeout(const Duration(minutes: 4));
    } catch (_) {
      // Ignored — the periodic/login pushes will catch it next time.
    } finally {
      if (dialogShown && rootNavigatorKey.currentState?.canPop() == true) {
        rootNavigatorKey.currentState!.pop();
      }
      await windowManager.destroy();
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'MagicBet Accounting',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
