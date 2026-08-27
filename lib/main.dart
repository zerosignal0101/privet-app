import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/shell_page.dart';
import 'state/daemon_state.dart';

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(daemonStateProvider.notifier).start();
    });
  }

  @override
  void dispose() {
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
