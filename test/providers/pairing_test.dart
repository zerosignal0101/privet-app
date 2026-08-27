import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/providers/pairing.dart';
import 'package:privet_app/services/ipc/events.dart';

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
}
