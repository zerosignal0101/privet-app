// "Leave Daemon Running" behavior:
//  - Desktop: closing the app stops the spawned daemon when the setting is
//    off, and keeps it running when the setting is on (wired through the
//    AppLifecycleListener onExitRequested in main.dart).
//  - Android: the setting is meaningless (in-process daemon pinned by the
//    foreground service) so the Settings tile is hidden there.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/main.dart';
import 'package:privet_app/pages/settings_page.dart';
import 'package:privet_app/state/daemon_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_daemon.dart';

class _RecordingSupervisor extends StubSupervisor {
  int stopCalls = 0;
  @override
  Future<void> stop() async {
    stopCalls++;
    await super.stop();
  }
}

void main() {
  testWidgets('closing the app stops the daemon when Leave Daemon Running is off',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final supervisor = _RecordingSupervisor();
    await tester.pumpWidget(ProviderScope(
      overrides: [daemonSupervisorProvider.overrideWithValue(supervisor)],
      child: const PrivetApp(),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('Privet'), findsOneWidget); // shell reached running

    await tester.binding.handleRequestAppExit();
    await tester.pump();
    expect(supervisor.stopCalls, 1);
  });

  testWidgets('closing the app keeps the daemon when Leave Daemon Running is on',
      (tester) async {
    SharedPreferences.setMockInitialValues({'leave_daemon_running': true});
    final supervisor = _RecordingSupervisor();
    await tester.pumpWidget(ProviderScope(
      overrides: [daemonSupervisorProvider.overrideWithValue(supervisor)],
      child: const PrivetApp(),
    ));
    await tester.pump();
    await tester.pump();

    await tester.binding.handleRequestAppExit();
    await tester.pump();
    expect(supervisor.stopCalls, 0);
  });

  testWidgets('settings shows Leave Daemon Running on desktop', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      SharedPreferences.setMockInitialValues({});
      final daemon = await bootTestDaemon(scriptFromHandlers({
        'list_trusted': (id, _) => okResponse(id, 'trusted', <Object?>[]),
        'get_identity': (id, _) => okResponse(id, 'identity', {
              'device_fingerprint': 'fp',
              'device_name': 'pc',
            }),
        'get_runtime_config': (id, _) => okResponse(id, 'runtime_config', {
              'accept_all_trusted': false,
              'collision_policy': 'rename',
              'save_dir': 'C:\\received',
            }),
      }));
      addTearDown(daemon.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: daemon.container,
        child: const MaterialApp(home: SettingsPage()),
      ));
      await tester.pump();
      expect(find.text('Leave Daemon Running'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('settings hides Leave Daemon Running on Android', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      SharedPreferences.setMockInitialValues({});
      final daemon = await bootTestDaemon(scriptFromHandlers({
        'list_trusted': (id, _) => okResponse(id, 'trusted', <Object?>[]),
        'get_identity': (id, _) => okResponse(id, 'identity', {
              'device_fingerprint': 'fp',
              'device_name': 'pc',
            }),
        'get_runtime_config': (id, _) => okResponse(id, 'runtime_config', {
              'accept_all_trusted': false,
              'collision_policy': 'rename',
              'save_dir': 'C:\\received',
            }),
      }));
      addTearDown(daemon.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: daemon.container,
        child: const MaterialApp(home: SettingsPage()),
      ));
      await tester.pump();
      expect(find.text('Leave Daemon Running'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
