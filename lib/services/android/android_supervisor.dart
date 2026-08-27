import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;

import '../daemon_supervisor.dart';
import '../device_name.dart';
import '../ipc/android_channel_transport.dart';
import 'daemon_bundle.dart';

const _daemonChannel = MethodChannel('privet/daemon');

/// Builds the on-device daemon supervisor: write the config and point the
/// transport at the app-private unix socket. The daemon runs in-process — Kotlin
/// loads `libprivetd_embed.so` and runs it on a thread — so the "spawner" just
/// asks Kotlin to start it and the supervisor polls the socket until it
/// answers. Used by [DaemonStateNotifier.start] when running on Android.
Future<DaemonSupervisor> androidSupervisor() async {
  final bundle = await AndroidDaemonBundle.resolve(
    deviceName: await resolveDefaultDeviceName(),
  );
  final config = await bundle.writeConfig();
  // The in-process daemon creates its own data/save dirs; the app pre-creates
  // the external save dir since a spawned child is denied doing so on modern
  // Android.
  await Directory(bundle.saveDir).create(recursive: true);
  return DaemonSupervisor(
    endpoint: bundle.socketPath,
    configPath: config,
    spawner: () => _startInProcess(bundle),
    stopHandler: () => _stopInProcess(),
    transportFactory: () => AndroidChannelTransport(bundle.socketPath),
  );
}

Future<Process?> _startInProcess(AndroidDaemonBundle bundle) async {
  try {
    await _daemonChannel.invokeMethod('start', {
      'configPath': bundle.configPath,
      'ipcPath': bundle.socketPath,
    });
  } catch (_) {
    // Channel unavailable (host tests); the supervisor surfaces the error when
    // the daemon never becomes reachable.
  }
  return null; // in-process: there is no child Process to supervise.
}

Future<void> _stopInProcess() async {
  try {
    await _daemonChannel.invokeMethod('stop');
  } catch (_) {
    // Channel unavailable — nothing to stop.
  }
}
