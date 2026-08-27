import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/daemon_supervisor.dart';
import '../services/ipc/dto.dart';
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
    configPath: null, // default config; app-managed config file lands in Plan 4
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
      final service = await ref.read(daemonSupervisorProvider).ensureRunning();
      state = DaemonSnapshot(kind: DaemonStateKind.running, service: service);
    } catch (e) {
      state = DaemonSnapshot(kind: DaemonStateKind.error, error: e.toString());
    }
  }

  Future<void> stop() async {
    await ref.read(daemonSupervisorProvider).stop();
    state = DaemonSnapshot(kind: DaemonStateKind.stopped);
  }

  Future<void> restart() async {
    await stop();
    await start();
  }
}
