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
