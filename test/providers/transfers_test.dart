import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/providers/transfers.dart';
import 'package:privet_app/services/ipc/events.dart';

void main() {
  ActiveTransfersNotifier fresh() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container.read(activeTransfersProvider.notifier);
  }

  test('transfer lifecycle: preparing -> offered -> progress -> completed',
      () {
    final n = fresh();
    n.applyEvent(TransferPreparingEvent(1, 't-1'));
    expect(n.state['t-1']!.state, TransferState.preparing);

    n.applyEvent(TransferOfferedEvent(2, 't-1', 3, 300));
    expect(n.state['t-1']!.isAwaitingAccept, isTrue);
    expect(n.state['t-1']!.direction, 'receive');

    n.applyEvent(TransferProgressEvent(3, 't-1', 150, 300));
    expect(n.state['t-1']!.state, TransferState.transferring);
    expect(n.state['t-1']!.fraction, closeTo(0.5, 0.001));

    n.applyEvent(TransferCompletedEvent(4, 't-1'));
    expect(n.state['t-1']!.state, TransferState.completed);
  });

  test('failed transfer surfaces the daemon error and retryability', () {
    final n = fresh();
    n.applyEvent(TransferPreparingEvent(1, 't-2'));
    n.applyEvent(TransferFailedEvent(2, 't-2', 'disk_full', false, false));
    final t = n.state['t-2']!;
    expect(t.state, TransferState.failed);
    expect(t.errorCode, 'disk_full');
    expect(t.retryable, isFalse);
  });

  test('pause and resume preserve progress', () {
    final n = fresh();
    n.applyEvent(TransferPreparingEvent(1, 't-3'));
    n.applyEvent(TransferProgressEvent(2, 't-3', 60, 120));
    n.applyEvent(TransferPausedEvent(3, 't-3', 'user'));
    expect(n.state['t-3']!.state, TransferState.paused);
    n.applyEvent(TransferResumedEvent(4, 't-3'));
    expect(n.state['t-3']!.state, TransferState.transferring);
    expect(n.state['t-3']!.verifiedBytes, 60);
  });

  test('progress for an unknown transfer is ignored', () {
    final n = fresh();
    n.applyEvent(TransferProgressEvent(1, 'ghost', 10, 20));
    expect(n.state, isEmpty);
  });
}
