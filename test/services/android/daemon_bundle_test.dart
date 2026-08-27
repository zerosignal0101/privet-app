import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/android/daemon_bundle.dart';
import 'package:privet_app/services/android/daemon_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Directory> tempDir() async {
    final tmp = await Directory.systemTemp.createTemp('privet-bundle');
    addTearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });
    return tmp;
  }

  test('writeConfig emits strict daemon JSON with real ports', () async {
    final tmp = await tempDir();
    final bundle = AndroidDaemonBundle(
      appFilesDir: tmp.path,
      externalFilesDir: '${tmp.path}/ext',
    );
    final cfgPath = await bundle.writeConfig();
    final cfg =
        jsonDecode(await File(cfgPath).readAsString()) as Map<String, dynamic>;
    expect(cfg['save_dir'], endsWith('Privet'));
    expect(cfg['ipc_endpoint'], bundle.socketPath);
    expect(cfg['quic_port'], 47808);
    expect(cfg['tcp_port'], 47808);
    expect(cfg['discovery_port'], 47808);
    expect(cfg['data_dir'], endsWith('privet/data'));
  });

  test('encodeDaemonConfig is deterministic and addressable', () {
    final cfg = jsonDecode(encodeDaemonConfig(
      deviceName: 'phone',
      dataDir: '/data/user/0/x/privet/data',
      saveDir: '/storage/emulated/0/Android/data/x/files/Privet',
      socketPath: '/data/user/0/x/privet/privet.sock',
    )) as Map<String, dynamic>;
    expect(cfg['device_name'], 'phone');
    expect(
      cfg.keys,
      containsAll([
        'device_name',
        'data_dir',
        'save_dir',
        'ipc_endpoint',
        'quic_port',
        'tcp_port',
        'discovery_port',
      ]),
    );
  });
}
