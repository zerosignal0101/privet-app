import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/shell_page.dart';
import 'state/daemon_state.dart';

/// Native → Dart: the Windows runner intercepts WM_CLOSE here because the
/// engine's cancelable-exit support (which would call `onExitRequested`) was
/// reverted upstream — closing the window otherwise never lets Dart clean up,
/// so a spawned privetd keeps running regardless of "Leave Daemon Running".
const MethodChannel _windowChannel = MethodChannel('privet/window');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: PrivetApp()));
}

class PrivetApp extends ConsumerStatefulWidget {
  const PrivetApp({super.key});

  @override
  ConsumerState<PrivetApp> createState() => _PrivetAppState();
}

class _PrivetAppState extends ConsumerState<PrivetApp> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    // macOS/Linux (and any engine that supports cancelable exit): the close
    // request arrives through onExitRequested. On Windows this never fires
    // (engine reverted WM_CLOSE interception), so the runner intercepts the
    // close and calls the same cleanup via the "privet/window" channel below.
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        // Desktop: honor "Leave Daemon Running" by stopping the spawned daemon
        // when the app closes, unless the user opted to keep it. Android never
        // reaches this path (no window-close exit; the in-process daemon is
        // pinned by the foreground service), and stop() is a no-op there.
        await ref.read(daemonStateProvider.notifier).stopUnlessLeavingRunning();
        return AppExitResponse.exit;
      },
    );
    _windowChannel.setMethodCallHandler(_onWindowClose);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(daemonStateProvider.notifier).start();
    });
  }

  /// Native window close (Windows runner): stop the daemon unless the user
  /// chose "Leave Daemon Running", then let the native side close the window.
  /// The native side waits for this reply, so bound the cleanup — a stalled
  /// stop must never leave the window hanging.
  Future<Object?> _onWindowClose(MethodCall call) async {
    if (call.method != 'onWindowClose') return null;
    await Future.any([
      ref.read(daemonStateProvider.notifier).stopUnlessLeavingRunning(),
      Future<void>.delayed(const Duration(seconds: 3)),
    ]);
    return null;
  }

  @override
  void dispose() {
    _windowChannel.setMethodCallHandler(null);
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final daemon = ref.watch(daemonStateProvider);
    return MaterialApp(
      title: 'Privet',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      debugShowCheckedModeBanner: false,
      home: switch (daemon.kind) {
        DaemonStateKind.starting =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
        DaemonStateKind.error => _ErrorScreen(
            error: daemon.error,
            onRetry: () => ref.read(daemonStateProvider.notifier).start()),
        _ => const ShellPage(),
      },
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({this.error, this.onRetry});
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Daemon unavailable',
                style: Theme.of(context).textTheme.titleMedium),
            if (error != null)
              Padding(padding: const EdgeInsets.all(8), child: Text(error!)),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ]),
        ),
      );
}
