import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/providers/pairing.dart';
import 'package:privet_app/providers/peers.dart';
import 'package:privet_app/services/ipc/events.dart';

import '../support/test_daemon.dart';

void main() {
  test('pairing request lifecycle', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = container.read(pairingProvider.notifier);

    n.applyEvent(PairingRequestedEvent(1, 'fp'));
    expect(n.state, hasLength(1));
    expect(n.state.single.deviceFingerprint, 'fp');

    // Duplicate requests for the same fingerprint are not re-added.
    n.applyEvent(PairingRequestedEvent(2, 'fp'));
    expect(n.state, hasLength(1));

    n.applyEvent(PairingResultEvent(3, 'fp', true, null));
    expect(n.state, isEmpty);
  });

  test('resolve drops a pending request', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = container.read(pairingProvider.notifier);

    n.applyEvent(PairingRequestedEvent(1, 'fp-a'));
    n.applyEvent(PairingRequestedEvent(2, 'fp-b'));
    n.resolve('fp-a');
    expect(n.state.single.deviceFingerprint, 'fp-b');
  });

  test('successful pairing result refreshes the trusted list', () async {
    // The responder (e.g. a desktop accepting a scanned QR) learns a pairing
    // completed only through the pairing_result event; without invalidating the
    // trusted lists here, Trusted Devices stays stale until a daemon restart.
    var trustedCalls = 0;
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'list_trusted': (id, _) {
        trustedCalls++;
        return okResponse(id, 'trusted', <dynamic>[]);
      },
    }));
    addTearDown(daemon.dispose);

    await daemon.container.read(trustedListProvider.future);
    expect(trustedCalls, 1);

    daemon.container.read(pairingProvider.notifier); // subscribe to events
    daemon.transport.inject({
      'type': 'event',
      'sequence': 1,
      'event': {
        'name': 'pairing_result',
        'data': {'device_fingerprint': 'fp', 'success': true, 'error': null},
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await daemon.container.read(trustedListProvider.future);
    expect(trustedCalls, greaterThan(1));

    // A failed pairing does not change the trusted list.
    final before = trustedCalls;
    daemon.transport.inject({
      'type': 'event',
      'sequence': 2,
      'event': {
        'name': 'pairing_result',
        'data': {'device_fingerprint': 'fp', 'success': false, 'error': 'no_pending'},
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(trustedCalls, before);

    // UncontrolledProviderScope does not own the container; dispose it so
    // activeTransfersProvider's periodic reconcile timer is cancelled.
    daemon.dispose();
  });
}
