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

/// A transport whose connect() fails — for exercising the shutdown helper
/// against a daemon that is not running.
class _ThrowingTransport implements Transport {
  @override
  Future<TransportConnection> connect() async => throw StateError('no daemon');
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

  test('shutdownAttachedDaemon asks the daemon to stop over IPC', () async {
    // A daemon the app attached to (not spawned) has no child Process, so stop
    // must tell it to shut down over the endpoint. The daemon answers the
    // connection handshake, then the shutdown request.
    var shutdownSeen = false;
    final transport = MemoryTransport((requests) => requests.map((req) {
          final id = req['request_id'] as String;
          final method = ((req['request'] as Map<String, dynamic>)['method'])
              as String;
          switch (method) {
            case 'get_status':
              return {
                'type': 'response',
                'request_id': id,
                'payload': {
                  'kind': 'status',
                  'data': {
                    'protocol_version': 1,
                    'daemon_version': '0.1.0',
                    'session_id': 's',
                    'device_fingerprint': 'fp',
                    'quic_addr': 'q',
                    'tcp_addr': 't',
                    'active_transfers': <String>[],
                  },
                },
              };
            case 'subscribe_events':
              return {
                'type': 'response',
                'request_id': id,
                'payload': {
                  'kind': 'event_replay',
                  'data': {
                    'events': <Object?>[],
                    'oldest_available': null,
                    'latest': 0,
                  },
                },
              };
            case 'shutdown':
              shutdownSeen = true;
              return {
                'type': 'response',
                'request_id': id,
                'payload': {'kind': 'ack', 'data': null},
              };
          }
          throw StateError('unexpected method: $method');
        }).toList());

    await shutdownAttachedDaemon('test-endpoint',
        transportFactory: () => transport);
    expect(shutdownSeen, isTrue, reason: 'attached daemon must be told to stop');
  });

  test('shutdownAttachedDaemon tolerates an unreachable daemon', () async {
    // No daemon on the endpoint: connect fails and the helper must not throw.
    await shutdownAttachedDaemon('test-endpoint',
        transportFactory: () => _ThrowingTransport());
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
