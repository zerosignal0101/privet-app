import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/providers/transfers.dart';
import 'package:privet_app/services/ipc/dto.dart';
import 'package:privet_app/services/ipc/events.dart';

import '../support/test_daemon.dart';

void main() {
  ActiveTransfersNotifier fresh() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container.read(activeTransfersProvider.notifier);
  }

  test('incoming offer lifecycle: offered -> progress -> completed', () {
    final n = fresh();
    // A receiver never gets `transfer_preparing` first — only the offer.
    n.applyEvent(TransferOfferedEvent(1, 't-1', 3, 300));
    expect(n.state['t-1']!.isAwaitingAccept, isTrue);
    expect(n.state['t-1']!.direction, 'receive');

    n.applyEvent(TransferProgressEvent(2, 't-1', 150, 300));
    expect(n.state['t-1']!.state, TransferState.transferring);
    expect(n.state['t-1']!.fraction, closeTo(0.5, 0.001));

    n.applyEvent(TransferCompletedEvent(3, 't-1'));
    expect(n.state['t-1']!.state, TransferState.completed);
  });

  test(
      'sender-side transfer_offered keeps the send direction and is not '
      'awaiting accept', () {
    final n = fresh();
    // A send: transfer_preparing creates the tile, then the sender daemon
    // echoes transfer_offered once its offer reaches the remote receiver.
    n.applyEvent(TransferPreparingEvent(1, 't-send'));
    n.applyEvent(TransferOfferedEvent(2, 't-send', 2, 200));

    final t = n.state['t-send']!;
    expect(t.direction, 'send');
    expect(t.isAwaitingAccept, isFalse);
    expect(t.state, TransferState.preparing);
    expect(t.totalBytes, 200);

    // Progress on a send keeps the send direction (not treated as receive).
    n.applyEvent(TransferProgressEvent(3, 't-send', 100, 200));
    expect(n.state['t-send']!.direction, 'send');
    expect(n.state['t-send']!.state, TransferState.transferring);
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

  test(
      'incoming offer with auto-accept on skips the confirm prompt and shows '
      'a receive in progress', () {
    final n = fresh();
    n.applyEvent(RuntimeConfigChangedEvent(1, RuntimeConfigDto(
        acceptAllTrusted: true, collisionPolicy: 'rename', saveDir: 'C:\\x')));
    n.applyEvent(TransferOfferedEvent(2, 't-auto', 2, 200));

    final t = n.state['t-auto']!;
    expect(t.direction, 'receive');
    expect(t.isAwaitingAccept, isFalse,
        reason: 'auto-accepted offers must not show a confirm prompt');
    expect(t.state, TransferState.transferring);
    expect(t.totalBytes, 200);

    // Progress continues normally on an auto-accepted receive.
    n.applyEvent(TransferProgressEvent(3, 't-auto', 100, 200));
    expect(n.state['t-auto']!.state, TransferState.transferring);
    expect(n.state['t-auto']!.fraction, closeTo(0.5, 0.001));
  });

  test('auto-accept off (default) still asks for a decision', () {
    final n = fresh();
    n.applyEvent(RuntimeConfigChangedEvent(1, RuntimeConfigDto(
        acceptAllTrusted: false, collisionPolicy: 'rename', saveDir: 'C:\\x')));
    n.applyEvent(TransferOfferedEvent(2, 't-manual', 1, 50));
    final t = n.state['t-manual']!;
    expect(t.isAwaitingAccept, isTrue);
    expect(t.state, TransferState.offered);
  });

  test('auto-accept is picked up from the daemon runtime config on boot', () async {
    // The daemon reports "Accept All Trusted"; the transfers notifier caches it
    // from get_runtime_config so the very first incoming offer skips the prompt.
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_runtime_config': (id, _) => okResponse(id, 'runtime_config', {
        'accept_all_trusted': true,
        'collision_policy': 'rename',
        'save_dir': 'C:\\received',
      }),
    }));
    addTearDown(daemon.dispose);

    final n = daemon.container.read(activeTransfersProvider.notifier);
    // build() fires _loadAutoAccept; wait for the config round-trip.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    n.applyEvent(TransferOfferedEvent(1, 't-boot', 2, 200));

    final t = n.state['t-boot']!;
    expect(t.isAwaitingAccept, isFalse);
    expect(t.state, TransferState.transferring);
  });

  test('auto-accepted receive resolves via the wire (offered -> progress -> completed)',
      () async {
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_runtime_config': (id, _) => okResponse(id, 'runtime_config', {
        'accept_all_trusted': true,
        'collision_policy': 'rename',
        'save_dir': r'C:\received',
      }),
    }));
    addTearDown(daemon.dispose);

    final n = daemon.container.read(activeTransfersProvider.notifier);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    daemon.transport.inject(_event(1, 'runtime_config_changed', {
      'accept_all_trusted': true,
      'collision_policy': 'rename',
      'save_dir': r'C:\received',
    }));
    daemon.transport.inject(_event(2, 'transfer_offered', {
      'transfer_id': 't-wire',
      'file_count': 2,
      'total_bytes': 400,
    }));
    daemon.transport.inject(_event(3, 'transfer_progress', {
      'transfer_id': 't-wire',
      'verified_bytes': 200,
      'total_bytes': 400,
    }));
    daemon.transport.inject(_event(4, 'transfer_completed', {
      'transfer_id': 't-wire',
    }));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final t = n.state['t-wire'];
    expect(t, isNotNull, reason: 'offer must create the receive tile');
    expect(t!.state, TransferState.completed,
        reason: 'the terminal event must reach the notifier over the wire');
  });

  testWidgets(
      'a transferring tile that went silent is self-healed even when the daemon '
      'is unreachable', (tester) async {
    // The daemon answers the connect handshake and boot-time config, but every
    // get_status AFTER connect fails — simulating a dead IPC connection, the
    // case where a missed terminal event previously left a 0% tile forever
    // ("can't cancel, doesn't disappear").
    var statusCalls = 0;
    final daemon = await bootTestDaemon((requests) => requests.map((req) {
          final id = req['request_id'] as String;
          final request = req['request'] as Map<String, dynamic>;
          final method = request['method'] as String;
          switch (method) {
            case 'get_status':
              statusCalls++;
              if (statusCalls > 1) {
                return serverMessage('response', {
                  'request_id': id,
                  'payload': null,
                  'error': {'code': 'closed', 'message': 'client is not connected'},
                });
              }
              return statusResponse(id);
            case 'subscribe_events':
              return okResponse(id, 'event_replay',
                  {'events': <dynamic>[], 'oldest_available': null, 'latest': 0});
            case 'get_runtime_config':
              return okResponse(id, 'runtime_config', {
                'accept_all_trusted': true,
                'collision_policy': 'rename',
                'save_dir': r'C:\received',
              });
            default:
              throw StateError('unexpected method: $method');
          }
        }).toList());

    final n = daemon.container.read(activeTransfersProvider.notifier);
    // Pin the clock so the silence window can be advanced deterministically.
    var fakeNow = DateTime.now();
    n.clock = () => fakeNow;
    await tester.pump(const Duration(milliseconds: 50));

    // Auto-accepted receive offer -> transferring tile at 0% (the reported bug
    // shape: a tile that never advances because its events never arrive).
    n.applyEvent(TransferOfferedEvent(1, 't-stuck', 1, 100));
    expect(n.state['t-stuck']!.state, TransferState.transferring);

    // No further events arrive. The daemon is unreachable (get_status fails) so
    // the active-transfers reconcile can't prune the tile either. After the
    // silence window the self-heal must clear it.
    fakeNow = DateTime.now().add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();

    expect(n.state['t-stuck'], isNull,
        reason: 'a tile silent past stuckTimeout must self-heal even when the '
            'daemon is unreachable');

    // Dispose within the body so the periodic reconcile timer is cancelled
    // before the test framework's pending-timer invariant check.
    daemon.dispose();
  });
}

// --- transport-level: the full IPC delivery path (wire bytes -> client parser
// -> notifier) must resolve an auto-accepted receive the same way applyEvent
// does directly. This guards the `_onFrame` dedup/parsing path that a direct
// applyEvent test bypasses. Regression for the phone-side stuck-0% tile: if the
// wire events were dropped or mis-parsed after `transfer_offered`, the tile
// would freeze at 0% and never terminate.
Map<String, dynamic> _event(int seq, String name, Map<String, dynamic> data) =>
    serverMessage('event', {
      'sequence': seq,
      'event': {'name': name, 'data': data},
    });
