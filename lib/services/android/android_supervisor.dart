import 'dart:io';

import '../daemon_supervisor.dart';
import '../ipc/android_channel_transport.dart';
import 'daemon_bundle.dart';

/// Builds the on-device daemon supervisor: extract the bundled ELF, write the
/// config, and point the transport at the app-private unix socket. Used by
/// [DaemonStateNotifier.start] when running on Android.
Future<DaemonSupervisor> androidSupervisor() async {
  final bundle = await AndroidDaemonBundle.resolve();
  final executable = await bundle.extract();
  final config = await bundle.writeConfig();
  // The daemon (a spawned child) is denied creating the external-storage save
  // dir itself on modern Android, so pre-create it from the app's own context
  // before spawning.
  await Directory(bundle.saveDir).create(recursive: true);
  return DaemonSupervisor(
    endpoint: bundle.socketPath,
    executablePath: executable,
    configPath: config,
    transportFactory: () => AndroidChannelTransport(bundle.socketPath),
  );
}
