import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/daemon_supervisor.dart';
import 'package:privet_app/state/daemon_state.dart';

import '../../tool/privetd_path.dart';

void main() {
  test('provider tree reaches running and round-trips against a real daemon',
      () async {
    final bin = findPrivetd();
    if (bin == null) return; // requires a built privetd

    final dir = await Directory.systemTemp.createTemp('privet-app-smoke');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    final endpoint = Platform.isWindows
        ? r'\\.\pipe\privet-app-smoke-' +
            DateTime.now().microsecondsSinceEpoch.toRadixString(16)
        : '${dir.path}/privet.sock';
    final configPath = '${dir.path}/config.json';
    await File(configPath).writeAsString(jsonEncode({
      'device_name': 'app-smoke',
      'data_dir': '${dir.path}/data',
      'save_dir': '${dir.path}/received',
      'ipc_endpoint': endpoint,
      'quic_port': 0,
      'tcp_port': 0,
      'discovery_port': 0,
    }));

    // Point the provider tree at the real daemon (attach-or-spawn).
    final container = ProviderContainer(overrides: [
      daemonSupervisorProvider.overrideWithValue(DaemonSupervisor(
        endpoint: endpoint,
        executablePath: bin,
        configPath: configPath,
      )),
    ]);
    addTearDown(() async {
      try {
        await container.read(daemonStateProvider).service?.shutdown();
      } catch (_) {}
      await container.read(daemonSupervisorProvider).stop();
      container.dispose();
    });

    final notifier = container.read(daemonStateProvider.notifier);
    final states = <DaemonStateKind>[];
    container.listen(daemonStateProvider, (_, next) => states.add(next.kind));
    await notifier.start();

    expect(states, contains(DaemonStateKind.running));

    // A real service is reachable through the provider tree and speaks the
    // real wire protocol.
    final snapshot = container.read(daemonStateProvider);
    expect(snapshot.service, isNotNull);
    final identity = await snapshot.service!.identity();
    expect(identity.deviceFingerprint, isNotEmpty);

    final config = await snapshot.service!.runtimeConfig();
    expect(config.saveDir, '${dir.path}/received');
  }, timeout: const Timeout(Duration(minutes: 1)));
}
