import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/android/android_supervisor.dart';
import '../services/android/daemon_bundle.dart';
import '../services/daemon_supervisor.dart';
import '../services/device_name.dart';
import '../services/ipc/dto.dart';
import '../providers/settings.dart';
import '../services/privet_service.dart';

enum DaemonStateKind { stopped, starting, running, error }

class DaemonSnapshot {
  DaemonSnapshot({required this.kind, this.service, this.error});
  final DaemonStateKind kind;
  final PrivetService? service;
  final String? error;
}

/// Locates a bundled or adjacent `privetd` binary. On Windows: app dir +
/// `privetd.exe`, then the sibling privet repo's `target/{debug,release}` so a
/// dev `flutter run` can spawn the daemon. (Android extraction is Plan 4.)
/// Returns null to run attach-only.
String? discoverPrivetd() {
  if (Platform.isWindows) {
    final local = File('${Directory.current.path}/privetd.exe');
    if (local.existsSync()) return local.path;
  }
  final repo = Platform.environment['PRIVET_REPO'] ?? r'D:\C-Codes\privet';
  final exe = Platform.isWindows ? 'privetd.exe' : 'privetd';
  for (final profile in const ['debug', 'release']) {
    final candidate = File('$repo/target/$profile/$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

final daemonEndpointProvider = Provider<String>((ref) {
  if (Platform.isWindows) return defaultWindowsPipeName;
  return resolvePosixEndpoint();
});

final daemonSupervisorProvider = Provider<DaemonSupervisor>((ref) {
  final endpoint = ref.watch(daemonEndpointProvider);
  final bin = discoverPrivetd();
  return DaemonSupervisor(
    endpoint: endpoint,
    executablePath: bin,
    // The daemon config is written (device name + any persisted runtime
    // settings) in DaemonStateNotifier.start before the daemon is spawned.
    configPath: desktopConfigPath(),
  );
});

final daemonStateProvider =
    NotifierProvider<DaemonStateNotifier, DaemonSnapshot>(DaemonStateNotifier.new);

/// The daemon's current `get_status` snapshot (addresses for the pairing QR).
final daemonStatusProvider = FutureProvider<DaemonStatus?>((ref) async {
  return ref.watch(daemonStateProvider).service?.status();
});

class DaemonStateNotifier extends Notifier<DaemonSnapshot> {
  @override
  DaemonSnapshot build() => DaemonSnapshot(kind: DaemonStateKind.stopped);

  Future<void> start() async {
    state = DaemonSnapshot(kind: DaemonStateKind.starting);
    try {
      // On Android the daemon is a bundled ELF extracted + spawned in the app
      // sandbox; everywhere else we attach-or-spawn an adjacent/dev privetd.
      final supervisor = Platform.isAndroid
          ? await androidSupervisor()
          : ref.read(daemonSupervisorProvider);
      // Write the daemon config before spawning so discovery announces the
      // configured device name (persisted "App Device Name" wins over the host).
      // Test stubs carry no config path, so this is a no-op for them.
      if (!Platform.isAndroid && supervisor.configPath != null) {
        await writeDesktopDeviceNameConfig();
      }
      final service = await supervisor.ensureRunning();
      // Pin the process so the daemon outlives UI backgrounding (Android only).
      if (Platform.isAndroid) await startForegroundService();
      state = DaemonSnapshot(kind: DaemonStateKind.running, service: service);
    } catch (e) {
      state = DaemonSnapshot(kind: DaemonStateKind.error, error: e.toString());
    }
  }

  Future<void> stop() async {
    await ref.read(daemonSupervisorProvider).stop();
    state = DaemonSnapshot(kind: DaemonStateKind.stopped);
  }

  /// Stops the daemon on app exit unless the user chose to leave it running
  /// ("Leave Daemon Running"). Only reached on desktop, where closing the last
  /// window requests an app exit; on Android the in-process daemon dies with
  /// the process and this path never fires.
  Future<void> stopUnlessLeavingRunning() async {
    // Read the persisted pref, not provider state: the Settings tab may never
    // have been opened this session, so settingsProvider may not have loaded.
    if (await loadLeaveDaemonRunningPref()) return;
    await stop();
  }

  Future<void> restart() async {
    await stop();
    await start();
  }
}
