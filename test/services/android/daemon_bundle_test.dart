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
    // Discovery is UDP on 47809, NOT 47808: QUIC (UDP 47808) and discovery
    // (UDP) would collide on the same port ("Address already in use").
    expect(cfg['discovery_port'], 47809);
    expect(cfg['data_dir'], endsWith('privet/data'));
  });

  test('writeConfig preserves daemon-persisted runtime fields', () async {
    final tmp = await tempDir();
    final bundle = AndroidDaemonBundle(
      appFilesDir: tmp.path,
      externalFilesDir: '${tmp.path}/ext',
    );
    // Simulate a previous run: the daemon persisted a user-chosen save dir plus
    // runtime toggles back into config.json via persist_config.
    File(bundle.configPath).parent.createSync(recursive: true);
    File(bundle.configPath).writeAsStringSync(jsonEncode({
      'device_name': 'old-model',
      'data_dir': '${tmp.path}/privet/data',
      'save_dir': '/storage/emulated/0/Download/Privet',
      'ipc_endpoint': bundle.socketPath,
      'quic_port': 47808,
      'tcp_port': 47808,
      'discovery_port': 47809,
      'accept_all_trusted': true,
      'collision_policy': 'overwrite',
    }));
    await bundle.writeConfig();
    final cfg = jsonDecode(await File(bundle.configPath).readAsString())
        as Map<String, dynamic>;
    // The user's save directory survives a restart...
    expect(cfg['save_dir'], '/storage/emulated/0/Download/Privet');
    // ...and so do the other daemon-persisted toggles.
    expect(cfg['accept_all_trusted'], isTrue);
    expect(cfg['collision_policy'], 'overwrite');
  });

  test('writeConfig refreshes app-owned structural keys', () async {
    final tmp = await tempDir();
    final bundle = AndroidDaemonBundle(
      appFilesDir: tmp.path,
      externalFilesDir: '${tmp.path}/ext',
      deviceName: 'my-phone',
    );
    File(bundle.configPath).parent.createSync(recursive: true);
    File(bundle.configPath).writeAsStringSync(jsonEncode({
      'device_name': 'stale-name',
      'data_dir': '/stale/data',
      'save_dir': '/storage/emulated/0/Download/Privet',
      'ipc_endpoint': '/stale/privet.sock',
      'quic_port': 9999,
      'tcp_port': 9999,
      'discovery_port': 9999,
    }));
    await bundle.writeConfig();
    final cfg = jsonDecode(await File(bundle.configPath).readAsString())
        as Map<String, dynamic>;
    // The device name and structural paths/ports are re-forced fresh...
    expect(cfg['device_name'], 'my-phone');
    expect(cfg['data_dir'], endsWith('privet/data'));
    expect(cfg['ipc_endpoint'], bundle.socketPath);
    expect(cfg['quic_port'], 47808);
    expect(cfg['discovery_port'], 47809);
    // ...while the persisted save dir is untouched.
    expect(cfg['save_dir'], '/storage/emulated/0/Download/Privet');
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
