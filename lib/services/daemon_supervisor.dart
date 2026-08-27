import 'dart:async';
import 'dart:io';

import 'ipc/client.dart';
import 'ipc/named_pipe_transport.dart';
import 'ipc/unix_socket_transport.dart';
import 'privet_service.dart';

enum DaemonState { stopped, starting, running, error }

/// Owns the daemon process lifecycle: attaches to a live `privetd` if present,
/// otherwise spawns one (from [executablePath]) with [configPath] and polls the
/// IPC endpoint until it answers. Reconnect after a crash is the caller's job
/// via a fresh `ensureRunning()` — the supervisor is the single owner of
/// process + connection state.
class DaemonSupervisor {
  DaemonSupervisor({
    required this.endpoint,
    this.executablePath,
    this.configPath,
    Transport Function()? transportFactory,
    this.spawner,
    this.attach,
    this.connectAttempts = 50,
  }) : _transportFactory = transportFactory ?? (() => _transportFor(endpoint));

  final String endpoint;
  final String? executablePath;
  final String? configPath;
  final int connectAttempts;

  final Transport Function() _transportFactory;

  /// Injectable test seams; when null the supervisor builds its own client.
  final Future<Process> Function()? spawner;
  final Future<PrivetService> Function()? attach;

  final _state = StreamController<DaemonState>.broadcast();
  Process? _process;
  Stream<DaemonState> get state => _state.stream;

  Future<PrivetService> ensureRunning() async {
    _set(DaemonState.starting);

    final attached = await _attachOnce();
    if (attached != null) {
      _set(DaemonState.running);
      return attached;
    }

    if (executablePath == null) {
      _set(DaemonState.error);
      throw StateError('no daemon running and no executablePath to spawn');
    }

    _process = await (spawner ?? _spawnDefault)();
    // exitCode is a Future, never null — track actual exit via its completion.
    var processExited = false;
    unawaited(_process!.exitCode.then((_) => processExited = true,
        onError: (_) => processExited = true));
    for (var i = 0; i < connectAttempts; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final service = await _attachOnce();
      if (service != null) {
        _set(DaemonState.running);
        return service;
      }
      if (processExited) break;
    }
    _set(DaemonState.error);
    throw StateError(
        'daemon did not become reachable within $connectAttempts attempts');
  }

  Future<PrivetService?> _attachOnce() async {
    if (attach != null) {
      try {
        return await attach!();
      } catch (_) {
        return null;
      }
    }
    try {
      final client = PrivetIpcClient(_transportFactory());
      await client.connect();
      return PrivetService(client);
    } catch (_) {
      return null;
    }
  }

  Future<Process> _spawnDefault() {
    final args = <String>[];
    if (configPath != null) args.addAll(['--config', configPath!]);
    return Process.start(executablePath!, args);
  }

  Future<void> stop() async {
    final process = _process;
    if (process != null && process.kill()) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    _set(DaemonState.stopped);
  }

  void _set(DaemonState s) {
    if (_state.isClosed) return;
    _state.add(s);
  }

  static Transport _transportFor(String endpoint) {
    if (Platform.isWindows) return NamedPipeTransport(endpoint);
    return UnixSocketTransport(endpoint);
  }
}

const String defaultWindowsPipeName = r'\\.\pipe\privet-user-v1';

/// POSIX IPC endpoint mirroring privet-ipc's `default_endpoint()` (spec 09 §2):
/// `$XDG_RUNTIME_DIR/privet/privet.sock` when the env var is set, else a
/// username-scoped temp fallback. The app passes the *same* path as `--ipc` to
/// the daemon it spawns (and an explicit app-data path on Android), so the
/// supervisor's `endpoint` always matches the daemon's socket.
String resolvePosixEndpoint() {
  final runtime = Platform.environment['XDG_RUNTIME_DIR'];
  if (runtime != null && runtime.isNotEmpty) {
    return '$runtime/privet/privet.sock';
  }
  final user = (Platform.environment['USER'] ?? 'unknown')
      .replaceAll(RegExp('[^a-zA-Z0-9]'), '_');
  return '${Directory.systemTemp.path}/privet-$user/privet/privet.sock';
}
