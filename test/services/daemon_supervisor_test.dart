import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/daemon_supervisor.dart';
import 'package:privet_app/services/ipc/client.dart';
import 'package:privet_app/services/privet_service.dart';

class _NoTransport implements Transport {
  @override
  Future<TransportConnection> connect() async => throw UnimplementedError();
}

PrivetService _fakeService() => PrivetService(PrivetIpcClient(_NoTransport()));

class _FakeProcess implements Process {
  @override
  int get pid => 4242;
  // A never-completing exitCode means "still running".
  @override
  final Future<int> exitCode = Completer<int>().future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

void main() {
  test('attaches when a daemon is already reachable', () async {
    final supervisor = DaemonSupervisor(
      endpoint: 'test-endpoint',
      attach: () async => _fakeService(),
    );
    final service = await supervisor.ensureRunning();
    expect(service, isA<PrivetService>());
  });

  test('spawns then polls until connect succeeds', () async {
    var attempts = 0;
    final supervisor = DaemonSupervisor(
      endpoint: 'test-endpoint',
      executablePath: '/fake/privetd',
      configPath: '/fake/config.json',
      spawner: () async => _FakeProcess(),
      attach: () async {
        attempts++;
        if (attempts < 3) throw StateError('not up yet');
        return _fakeService();
      },
    );
    final service = await supervisor.ensureRunning();
    expect(service, isA<PrivetService>());
  });

  test('gives up after connectAttempts', () async {
    final supervisor = DaemonSupervisor(
      endpoint: 'x',
      executablePath: '/fake/privetd',
      spawner: () async => _FakeProcess(),
      attach: () async => throw StateError('never'),
      connectAttempts: 3,
    );
    await expectLater(supervisor.ensureRunning(), throwsStateError);
  });

  test('in-process spawner (null Process) polls until connect succeeds', () async {
    var attempts = 0;
    final supervisor = DaemonSupervisor(
      endpoint: 'test-endpoint',
      spawner: () async => null,
      attach: () async {
        attempts++;
        if (attempts < 3) throw StateError('not up yet');
        return _fakeService();
      },
    );
    final service = await supervisor.ensureRunning();
    expect(service, isA<PrivetService>());
    expect(attempts, greaterThanOrEqualTo(3));
  });

  test('in-process spawner with no daemon gives up', () async {
    final supervisor = DaemonSupervisor(
      endpoint: 'x',
      spawner: () async => null,
      attach: () async => throw StateError('never'),
      connectAttempts: 3,
    );
    await expectLater(supervisor.ensureRunning(), throwsStateError);
  });

  test('stop calls the stopHandler when there is no process', () async {
    var stopped = false;
    final supervisor = DaemonSupervisor(
      endpoint: 'x',
      spawner: () async => null,
      stopHandler: () async => stopped = true,
    );
    await supervisor.stop();
    expect(stopped, isTrue);
  });

  test('resolvePosixEndpoint mirrors the daemon default (POSIX)', () {
    if (Platform.isWindows) return; // POSIX-only
    const xdg = '/tmp/user-runtime';
    final previous = Platform.environment['XDG_RUNTIME_DIR'];
    Platform.environment['XDG_RUNTIME_DIR'] = xdg;
    expect(resolvePosixEndpoint(), '$xdg/privet/privet.sock');
    if (previous == null) {
      Platform.environment.remove('XDG_RUNTIME_DIR');
    } else {
      Platform.environment['XDG_RUNTIME_DIR'] = previous;
    }
    final endpoint = resolvePosixEndpoint();
    expect(endpoint, endsWith('/privet/privet.sock'));
    expect(endpoint, isNot(startsWith('$xdg/')));
  });
}
