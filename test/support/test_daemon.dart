import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:privet_app/services/daemon_supervisor.dart';
import 'package:privet_app/services/ipc/client.dart';
import 'package:privet_app/services/privet_service.dart';
import 'package:privet_app/state/daemon_state.dart';

/// Shared fakes for provider tests. The UI tests never touch a real daemon:
/// they drive `daemonStateProvider` into a running snapshot over a scripted
/// `MemoryTransport` (for request/response) and use `inject` for live events.

/// A transport whose connect() throws — for building a service whose methods
/// are never called (stub-daemon tests that only exercise state transitions).
class DeadTransport implements Transport {
  @override
  Future<TransportConnection> connect() async => throw UnimplementedError();
}

PrivetService deadService() => PrivetService(PrivetIpcClient(DeadTransport()));

/// A supervisor that returns [service] without contacting a real daemon.
class StubSupervisor extends DaemonSupervisor {
  StubSupervisor({PrivetService? service})
      : _service = service ?? deadService(),
        super(endpoint: 'test-endpoint');
  final PrivetService _service;
  @override
  Future<PrivetService> ensureRunning() async => _service;
}

/// A `DaemonStateNotifier` whose build() reports a running daemon with
/// [service]. Used to override `daemonStateProvider` in provider tests.
class RunningDaemonNotifier extends DaemonStateNotifier {
  RunningDaemonNotifier(this.service);
  final PrivetService service;
  @override
  DaemonSnapshot build() =>
      DaemonSnapshot(kind: DaemonStateKind.running, service: service);
}

/// A provider container whose daemon state is running against a scripted
/// `MemoryTransport` service, with the client already connected so the caller
/// can `inject` live events into `transport`.
class TestDaemon {
  TestDaemon(this.container, this.transport, this.service);
  final ProviderContainer container;
  final MemoryTransport transport;
  final PrivetService service;

  void dispose() => container.dispose();
}

/// Boots a running daemon over [script]. The script answers the connection
/// handshake (`get_status`, `subscribe_events`) plus any request the test
/// issues; live events are pushed via the returned [TestDaemon.transport].
Future<TestDaemon> bootTestDaemon(
    List<Map<String, dynamic>> Function(List<Map<String, dynamic>> requests)
        script) async {
  final transport = MemoryTransport(script);
  final client = PrivetIpcClient(transport);
  await client.connect();
  final service = PrivetService(client);
  final container = ProviderContainer(overrides: [
    daemonStateProvider.overrideWith(() => RunningDaemonNotifier(service)),
  ]);
  return TestDaemon(container, transport, service);
}

// ---- wire-message builders (shared by provider tests) ----------------------

Map<String, dynamic> serverMessage(String type, Map<String, dynamic> body) =>
    {'type': type, ...body};

Map<String, dynamic> okPayload(String kind, Object? data) =>
    {'kind': kind, 'data': data};

Map<String, dynamic> okResponse(String id, String kind, Object? data) =>
    serverMessage('response', {'request_id': id, 'payload': okPayload(kind, data)});

Map<String, dynamic> statusResponse(String id) =>
    statusResponseWithAddrs(id, null);

/// A `get_status` fixture. [localAddrs] controls the additive `local_addrs`
/// field: pass a list to include it, or null to omit it entirely (which is what
/// a daemon predating the field sends, and must parse as an empty list).
Map<String, dynamic> statusResponseWithAddrs(
        String id, List<Map<String, dynamic>>? localAddrs) =>
    okResponse(id, 'status', {
      'protocol_version': 1,
      'daemon_version': '0.1.0',
      'session_id': 'sess-A',
      'device_fingerprint': 'fp',
      'quic_addr': 'q',
      'tcp_addr': 't',
      'active_transfers': <String>[],
      'local_addrs': ?localAddrs,
    });

/// Builds a script from a per-method handler map; the connection handshake
/// (get_status + subscribe_events) is answered automatically. Handlers receive
/// the request id and params, and return one server message.
///
/// A test that needs a specific status fixture (e.g. `local_addrs`) can
/// override the handshake by putting its own `get_status` in [handlers].
List<Map<String, dynamic>> Function(List<Map<String, dynamic>>) scriptFromHandlers(
    Map<String, Map<String, dynamic> Function(String id, Map<String, dynamic> params)>
        handlers) {
  return (requests) => requests.map((req) {
        final id = req['request_id'] as String;
        final request = req['request'] as Map<String, dynamic>;
        final method = request['method'] as String;
        final params = (request['params'] as Map<String, dynamic>?) ?? const {};
        final h = handlers[method];
        if (h != null) return h(id, params);
        switch (method) {
          case 'get_status':
            return statusResponse(id);
          case 'subscribe_events':
            return okResponse(id, 'event_replay',
                {'events': <dynamic>[], 'oldest_available': null, 'latest': 0});
        }
        throw StateError('unexpected method: $method');
      }).toList();
}
