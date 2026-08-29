import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/shell_page.dart';
import 'providers/pending_share.dart';
import 'services/share_service.dart';
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
  ShareService? _shareService;
  StreamSubscription<PendingShareData>? _shareSub;

  @override
  void initState() {
    super.initState();
    // Registers the privet/share handler and pulls the cold-start stash into
    // pendingShareProvider. This lives at the app root, not the shell: the
    // shell is unmounted while the daemon starts (a spinner is shown), so a
    // pull owned by the shell would complete after the shell is disposed and
    // the pending share would be lost — the app would open on the home tab
    // instead of the send preparation page.
    _initShareHandling();
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
      onStateChange: (state) {
        // Foreground — pull any share data that was waiting. The onShare push
        // fires from onNewIntent while the app is running; this is the robust
        // fallback for a share that landed before the handler was ready (e.g.
        // while the daemon spinner was up on cold start).
        if (state == AppLifecycleState.resumed) {
          _shareService?.pull();
        }
      },
    );
    _windowChannel.setMethodCallHandler(_onWindowClose);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(daemonStateProvider.notifier).start();
    });
  }

  /// Registers the `privet/share` handler and pulls any pending share into
  /// [pendingShareProvider], which survives ShellPage rebuilds.
  void _initShareHandling() {
    final share = ShareService();
    _shareService = share;
    _shareSub = share.shares.listen(_handleShareData);
    share.start();
  }

  /// Route an incoming share (onShare push or getPendingShare pull) into
  /// [pendingShareProvider]; the shell navigates when it observes a non-null
  /// value (and on mount via _checkPendingShare).
  void _handleShareData(PendingShareData data) {
    if (!data.isEmpty) {
      ref.read(pendingShareProvider.notifier).set(data);
    }
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
    _shareSub?.cancel();
    _shareService?.dispose();
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
      // The UI is a single phone-width column (bottom nav + ListTiles). The
      // desktop runners open a phone-sized window (420×780) to match, and this
      // builder caps the content at a mobile width and paints the app's
      // background across the whole window, so a maximized window keeps the
      // mobile proportions beside the theme background instead of stretching or
      // showing black borders. Applied on every route so pushed pages (send
      // preparation, dialogs) stay inside the column too.
      builder: _mobileFrame,
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

/// The app is laid out for a phone-width column (bottom nav + dense ListTiles).
/// On phones/tablets the screen is already roughly that width, so the child
/// passes through untouched. On desktop the window is resized (in the native
/// runner) to a phone-like ratio that matches this layout; the column here
/// merely caps the content width if the user stretches or maximizes the window,
/// and the whole window is painted with the app's background color so the area
/// beside a wider-than-max column never shows the black native view background.
Widget _mobileFrame(BuildContext context, Widget? child) {
  final background = Theme.of(context).scaffoldBackgroundColor;
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    return ColoredBox(
        key: const ValueKey('phone-frame'),
        color: background,
        child: child ?? const SizedBox.shrink());
  }
  return ColoredBox(
    key: const ValueKey('phone-frame'),
    color: background,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SizedBox.expand(child: child ?? const SizedBox.shrink()),
      ),
    ),
  );
}
