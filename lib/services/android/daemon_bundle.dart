import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'daemon_config.dart';

/// Manages the on-device privetd lifecycle assets: extracts the bundled ELF
/// for this ABI out of `assets/bin/<abi>/privetd`, writes the daemon config,
/// and exposes the unix socket + external save dir.
///
/// Layout (all under the app sandbox):
///   `<files>/privet/bin/privetd`      — extracted executable
///   `<files>/privet/config.json`      — daemon config
///   `<files>/privet/privet.sock`      — IPC unix socket
///   `<external files>/Privet`         — received files (user-visible)
class AndroidDaemonBundle {
  AndroidDaemonBundle({
    required this.appFilesDir,
    required this.externalFilesDir,
    this.abi = 'arm64-v8a',
    this.assetRoot = 'assets/bin',
    this.deviceName = 'privet-device',
  });

  final String appFilesDir;
  final String externalFilesDir;
  final String abi;
  final String assetRoot;
  final String deviceName;

  String get _privetDir => '$appFilesDir/privet';
  String get socketPath => '$_privetDir/privet.sock';
  String get saveDir => '$externalFilesDir/Privet';

  /// Extracts the bundled daemon ELF and returns its path. Reuses an existing
  /// extraction so restart doesn't rewrite (and re-exec-fail on) a running bin.
  Future<String> extract() async {
    final binDir = Directory('$_privetDir/bin');
    await binDir.create(recursive: true);
    final target = File('${binDir.path}/privetd');
    if (!await target.exists()) {
      final data = await rootBundle.load('$assetRoot/$abi/privetd');
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    // App-private dirs are mounted executable for the app's uid; still set the
    // exec bit so Process.start can exec it. dart:io removed the File permission
    // mutators, so shell out to chmod. Skipped on Windows hosts (no mode bits).
    if (!Platform.isWindows) {
      await Process.run('chmod', ['700', target.path]);
    }
    return target.path;
  }

  /// Writes the daemon config and returns its path.
  Future<String> writeConfig() async {
    final dir = Directory(_privetDir);
    await dir.create(recursive: true);
    final file = File('${dir.path}/config.json');
    await file.writeAsString(
      encodeDaemonConfig(
        deviceName: deviceName,
        dataDir: '$_privetDir/data',
        saveDir: saveDir,
        socketPath: socketPath,
      ),
      flush: true,
    );
    return file.path;
  }

  /// Resolves the runtime dirs from path_provider and returns a fully
  /// configured bundle. Android-only — callers guard on [Platform.isAndroid].
  static Future<AndroidDaemonBundle> resolve({
    String deviceName = 'privet-device',
  }) async {
    final appFiles = (await getApplicationSupportDirectory()).path;
    final external = (await getExternalStorageDirectory())?.path ?? appFiles;
    return AndroidDaemonBundle(
      appFilesDir: appFiles,
      externalFilesDir: external,
      abi: await androidAbi(),
      deviceName: deviceName,
    );
  }
}
