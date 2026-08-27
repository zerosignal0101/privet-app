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
  return DaemonSupervisor(
    endpoint: bundle.socketPath,
    executablePath: executable,
    configPath: config,
    transportFactory: () => AndroidChannelTransport(bundle.socketPath),
  );
}
