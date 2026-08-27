import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';

import 'daemon_config.dart';

const _daemonServiceChannel = MethodChannel('privet/daemon_service');

/// Promotes the daemon process to a foreground service so Android doesn't kill
/// it (and its in-process daemon thread) when the UI is backgrounded.
/// Best-effort: if the channel is missing the daemon still runs, it just isn't
/// pinned. Call only after the daemon is confirmed running.
Future<void> startForegroundService() async {
  try {
    await _daemonServiceChannel.invokeMethod('start');
  } catch (_) {
    // Channel unavailable on this platform — keep the daemon running unpinned.
  }
}

/// Manages the on-device privetd runtime files: writes the daemon config and
/// exposes the unix socket + external save dir. The daemon binary itself ships
/// as a native library in jniLibs (`libprivetd_embed.so`) and is loaded
/// in-process by Kotlin's [PrivetDaemon] — there is nothing to extract.
///
/// Layout (all under the app sandbox):
///   `<files>/privet/config.json`      — daemon config
///   `<files>/privet/privet.sock`      — IPC unix socket
///   `<external files>/Privet`         — received files (user-visible)
class AndroidDaemonBundle {
  AndroidDaemonBundle({
    required this.appFilesDir,
    required this.externalFilesDir,
    this.deviceName = 'privet-device',
  });

  final String appFilesDir;
  final String externalFilesDir;
  final String deviceName;

  String get _privetDir => '$appFilesDir/privet';
  String get socketPath => '$_privetDir/privet.sock';
  String get configPath => '$_privetDir/config.json';
  String get saveDir => '$externalFilesDir/Privet';

  /// Writes the daemon config and returns its path.
  Future<String> writeConfig() async {
    final dir = Directory(_privetDir);
    await dir.create(recursive: true);
    final file = File(configPath);
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
      deviceName: deviceName,
    );
  }
}
