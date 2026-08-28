import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';

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
  ///
  /// Merges into the existing file instead of rewriting it from scratch: the
  /// daemon persists runtime settings (`save_dir`, `accept_all_trusted`,
  /// `collision_policy`, `pairing`) back into this same config.json via
  /// `persist_config`, so a fresh config on every start would discard the user's
  /// saved save directory and policy choices on the next launch. Only the
  /// app-owned structural keys are forced (device name + sandbox paths/ports);
  /// daemon-owned values already on disk win, and `save_dir` defaults to the
  /// app's external dir only when nothing was persisted yet.
  Future<String> writeConfig() async {
    final dir = Directory(_privetDir);
    await dir.create(recursive: true);
    final file = File(configPath);
    final Map<String, dynamic> config = file.existsSync()
        ? (jsonDecode(await file.readAsString()) as Map<String, dynamic>)
        : <String, dynamic>{};
    config
      ..['device_name'] = deviceName
      ..['data_dir'] = '$_privetDir/data'
      ..['ipc_endpoint'] = socketPath
      ..['quic_port'] = 47808
      ..['tcp_port'] = 47808
      ..['discovery_port'] = 47809;
    config.putIfAbsent('save_dir', () => saveDir);
    await file.writeAsString(jsonEncode(config), flush: true);
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
