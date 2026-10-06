// Regression: completing the phone-side "Enter their code" pairing flow must
// not crash. The dialog used to dispose its TextEditingController the moment
// showDialog's future resolved (i.e. at Navigator.pop), while the TextField was
// still mounted and animating out — the next frame's rebuild then hit
// "A TextEditingController was used after being disposed", which cascaded into
// the `_dependents.isEmpty` framework assertion on the red error screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/send_preparation_page.dart';
import 'package:privet_app/services/daemon_supervisor.dart';
import 'package:privet_app/services/ipc/client.dart';
import 'package:privet_app/services/privet_service.dart';
import 'package:privet_app/state/daemon_state.dart';

Map<String, dynamic> _msg(String type, Map<String, dynamic> body) =>
    {'type': type, ...body};
Map<String, dynamic> _payload(String kind, dynamic data) =>
    {'kind': kind, 'data': data};
Map<String, dynamic> _resp(String id, Map<String, dynamic> payload) =>
    _msg('response', {'request_id': id, 'payload': payload});

/// A fake daemon over [MemoryTransport]: answers `get_status` /
/// `subscribe_events` on connect, serves an empty trusted list until `pair`
/// succeeds, then serves the newly trusted peer. Drives the real page's
/// `ref.watch(trustedListProvider)` the same way the live daemon would.
Future<DaemonSupervisor> _fakeSupervisor() async {
  var paired = false;
  final transport = MemoryTransport((requests) {
    final replies = <Map<String, dynamic>>[];
    for (final req in requests) {
      final id = req['request_id'];
      final method = (req['request'] as Map<String, dynamic>)['method'];
      switch (method) {
        case 'get_status':
          replies.add(_resp(id as String, _payload('status', {
                'protocol_version': 1,
                'daemon_version': '0.1.0',
                'session_id': 'sess-A',
                'device_fingerprint': 'fp-phone',
                'quic_addr': 'q',
                'tcp_addr': 't',
                'active_transfers': <String>[],
              })));
          break;
        case 'subscribe_events':
          replies.add(_resp(id as String, _payload('event_replay', {
                'events': <Map<String, dynamic>>[],
                'oldest_available': null,
                'latest': 0,
              })));
          break;
        // The page asks for the peer list on entry, because its reachability
        // verdict reads the same discovery input the home page does. Answering
        // it is required, not optional: an unanswered request would leave the
        // IPC timeout timer pending and fail this test for the wrong reason.
        case 'list_peers':
          replies.add(_resp(id as String, _payload('peers', <Map<String, dynamic>>[])));
          break;
        case 'list_trusted':
          replies.add(_resp(id as String, _payload('trusted', paired
              ? [
                  {
                    'device_fingerprint': 'fp-pc',
                    'device_name': 'pc',
                    'trust_state': 'Trusted',
                    'spki_hex': 'x',
                    'first_paired_ts': 1,
                    'last_seen_ts': 1,
                  }
                ]
              : <Map<String, dynamic>>[])));
          break;
        case 'pair':
          paired = true;
          replies.add(_resp(id as String, _payload('pairing_result', {
                'paired': true,
                'device_fingerprint': 'fp-pc',
              })));
          break;
      }
    }
    return replies;
  });

  final client = PrivetIpcClient(transport);
  await client.connect();
  return DaemonSupervisor(endpoint: 'mem', attach: () async => PrivetService(client));
}

void main() {
  testWidgets('entering the remote code and pairing does not crash the page',
      (tester) async {
    final supervisor = await _fakeSupervisor();
    final container = ProviderContainer(overrides: [
      daemonSupervisorProvider.overrideWithValue(supervisor),
    ]);
    addTearDown(container.dispose);
    await container.read(daemonStateProvider.notifier).start();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: SendPreparationPage(
          initialPeerFingerprint: 'fp-pc',
          initialPeerName: 'pc',
        ),
      ),
    ));
    await tester.pump();

    // Peer is discovered but not trusted, so the pairing card is shown.
    expect(find.text('Enter their code'), findsOneWidget);

    await tester.tap(find.text('Enter their code'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    // The dialog closed and the page rebuilt without any framework assertion.
    expect(find.text('Pair'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
