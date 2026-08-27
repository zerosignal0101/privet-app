import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/daemon_supervisor.dart';

import '../../tool/privetd_path.dart';

void main() {
  test('real daemon: spawn, attach, identity, config, delete history', () async {
    final bin = findPrivetd();
    if (bin == null) return; // requires a built privetd

    final dir = await Directory.systemTemp.createTemp('privet-smoke');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    // On Windows the IPC endpoint is a named pipe; on POSIX a socket path.
    final endpoint = Platform.isWindows
        ? r'\\.\pipe\privet-smoke-' +
            DateTime.now().microsecondsSinceEpoch.toRadixString(16)
        : '${dir.path}/privet.sock';
    final configPath = '${dir.path}/config.json';
    await File(configPath).writeAsString(jsonEncode({
      'device_name': 'smoke',
      'data_dir': '${dir.path}/data',
      'save_dir': '${dir.path}/received',
      'ipc_endpoint': endpoint,
      'quic_port': 0,
      'tcp_port': 0,
      'discovery_port': 0,
    }));

    final supervisor = DaemonSupervisor(
      endpoint: endpoint,
      executablePath: bin,
      configPath: configPath,
    );
    final service = await supervisor.ensureRunning();
    addTearDown(() async {
      try {
        await service.shutdown();
      } catch (_) {}
      await supervisor.stop();
    });

    final identity = await service.identity();
    expect(identity.deviceFingerprint, isNotEmpty);

    final config = await service.runtimeConfig();
    expect(config.saveDir, '${dir.path}/received');

    // delete_history_entry is a plain DELETE: a missing ID is not an error.
    await expectLater(service.deleteHistory('does-not-exist'), completes);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
