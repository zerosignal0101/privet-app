import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/daemon_supervisor.dart';
import 'package:privet_app/services/privet_service.dart';
import 'package:privet_app/state/daemon_state.dart';

import '../support/test_daemon.dart';

class _FailingSupervisor extends DaemonSupervisor {
  _FailingSupervisor() : super(endpoint: 'x');
  @override
  Future<PrivetService> ensureRunning() async => throw StateError('boom');
}

void main() {
  test('start transitions stopped -> starting -> running', () async {
    final container = ProviderContainer(overrides: [
      daemonSupervisorProvider.overrideWithValue(StubSupervisor()),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(daemonStateProvider.notifier);
    final states = <DaemonStateKind>[];
    container.listen(daemonStateProvider, (_, next) => states.add(next.kind));
    await notifier.start();
    expect(states, containsAllInOrder(
        [DaemonStateKind.starting, DaemonStateKind.running]));
    expect(container.read(daemonStateProvider).service, isNotNull);
  });

  test('start records an error when the daemon cannot be reached', () async {
    final container = ProviderContainer(overrides: [
      daemonSupervisorProvider.overrideWithValue(_FailingSupervisor()),
    ]);
    addTearDown(container.dispose);
    await container.read(daemonStateProvider.notifier).start();
    final state = container.read(daemonStateProvider);
    expect(state.kind, DaemonStateKind.error);
    expect(state.error, isNotNull);
  });

  test('stop resets to stopped', () async {
    final container = ProviderContainer(overrides: [
      daemonSupervisorProvider.overrideWithValue(StubSupervisor()),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(daemonStateProvider.notifier);
    await notifier.start();
    await notifier.stop();
    expect(container.read(daemonStateProvider).kind, DaemonStateKind.stopped);
  });
}
