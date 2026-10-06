// The send-to-address box must FOLLOW THE RECEIVER.
//
// The rule the box itself implements is deliberate and right: a `via` that is
// already set wins over the remembered address, because the user typed it on
// purpose (a peer met again on another network) and overwriting it would
// silently send to the old address. The failure mode is not that rule — it is
// the *state* the rule reads. A receiver change that left `viaIp` holding the
// previous receiver's address made peer A's typed address look like something
// the user had typed for peer B, so the box showed A's address and the send
// carried it. That is a wrong value crossing the IPC boundary, not a cosmetic
// display bug.
//
// These tests therefore assert on what the daemon is handed, not only on the
// rendered text.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/send_preparation_page.dart';
import 'package:privet_app/providers/send_preparation.dart';

import '../support/test_daemon.dart';

/// Bounded pump helper: enough frames for the FutureProviders (trusted list) to
/// resolve without waiting on an unbounded settle.
Future<void> _settleFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _identity = {
  'device_fingerprint': 'me',
  'device_name': 'mydev',
};
const _runtimeConfig = {
  'accept_all_trusted': false,
  'collision_policy': 'rename',
  'save_dir': r'C:\received',
};

/// The two receivers used throughout: `alpha` is A, `bravo` is B.
const _fpA = 'peer-a-fingerprint';
const _fpB = 'peer-b-fingerprint';

String _makeFile(String dirName) {
  final dir = Directory('${Directory.systemTemp.path}/$dirName')
    ..createSync(recursive: true);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final file = File('${dir.path}/a.txt')..writeAsStringSync('hello');
  return file.path;
}

/// The address box's current text, read from the field the user actually sees.
String _boxText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('via-address-field')))
    .controller!
    .text;

/// A booted daemon plus the `send` requests it was handed, in order.
typedef _Rig = ({TestDaemon daemon, List<Map<String, dynamic>?> sends});

/// Boots a daemon whose trust store holds the two receivers.
///
/// [aAddresses] / [bAddresses] control each receiver's remembered `addresses`
/// list; pass an empty list for a device the daemon has never reached.
Future<_Rig> _boot({
  required List<Map<String, dynamic>> aAddresses,
  required List<Map<String, dynamic>> bAddresses,
}) async {
  final sends = <Map<String, dynamic>?>[];
  final daemon = await bootTestDaemon(scriptFromHandlers({
    'get_identity': (id, _) => okResponse(id, 'identity', _identity),
    'get_runtime_config': (id, _) =>
        okResponse(id, 'runtime_config', _runtimeConfig),
    'list_trusted': (id, _) => listTrustedResponse(id, [
          trustedPeer(_fpA, name: 'alpha', addresses: aAddresses),
          trustedPeer(_fpB, name: 'bravo', addresses: bAddresses),
        ]),
    'send': (id, params) {
      sends.add(Map<String, dynamic>.from(params));
      return okResponse(
          id, 'transfer_queued', {'transfer_id': 't-${sends.length}'});
    },
  }));
  return (daemon: daemon, sends: sends);
}

/// A `device_discovered` event, used to put both receivers online.
Map<String, dynamic> _discovered(int seq, String fp, String name) => {
      'type': 'event',
      'sequence': seq,
      'event': {
        'name': 'device_discovered',
        'data': {'device_fingerprint': fp, 'device_name': name},
      },
    };

/// The page opened on receiver A, as if the user had picked alpha first.
///
/// Both receivers are put online: the page deliberately refuses to send to a
/// device that is not discovered unless an address is pinned
/// (`send_preparation_page.dart`, `_send`), and an offline B would abort before
/// the request is built. These tests are about the *contents* of that request,
/// so the receivers have to be reachable for it to exist.
Future<void> _pumpOnA(
    WidgetTester tester, TestDaemon daemon, String file) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: daemon.container,
    child: MaterialApp(
      home: SendPreparationPage(
        initialEntries: [
          SendFileEntry(path: file, relativePath: 'a.txt', size: 5),
        ],
        initialPeerFingerprint: _fpA,
        initialPeerName: 'alpha',
      ),
    ),
  ));
  await _settleFrames(tester);

  daemon.transport.inject(_discovered(1, _fpA, 'alpha'));
  daemon.transport.inject(_discovered(2, _fpB, 'bravo'));
  await _settleFrames(tester);
}

void main() {
  testWidgets('switching receiver clears the box and sends no via from A',
      (tester) async {
    // B has no remembered address, so B's own prefill is "empty". If A's
    // address survives the switch it is shown, and — worse — sent.
    final d = await _boot(
      aAddresses: [trustedPeerAddress('10.0.0.1', 47808, 47808, 3000)],
      bAddresses: const [],
    );
    addTearDown(d.daemon.dispose);

    final file = _makeFile('privet-via-switch-clear');
    await _pumpOnA(tester, d.daemon, file);

    // A is selected and its remembered address is pinned.
    expect(_boxText(tester), '10.0.0.1');
    expect(d.daemon.container.read(sendPreparationProvider).viaIp, '10.0.0.1');

    // The user presses "Change" and picks B. This is the exact call the peer
    // picker makes on selection.
    d.daemon.container
        .read(sendPreparationProvider.notifier)
        .setPeer(_fpB, name: 'bravo');
    await _settleFrames(tester);

    // The assertion that matters comes first: what the service received. In the
    // unfixed state a stale `via` also bypasses the page's offline gate, so the
    // request is really built — and it carries A's address under B's
    // fingerprint. Asserting the rendered text first would stop the test at the
    // cosmetic symptom and never reach the wrong value crossing the boundary.
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);

    expect(d.sends, hasLength(1), reason: 'the request must have been built');
    expect(d.sends.single!['device_fingerprint'], _fpB);
    expect(d.sends.single!.containsKey('via'), isFalse,
        reason: "receiver A's address must never cross the IPC boundary for B");

    // And the box the user reads agrees with what was sent: B's state, empty.
    expect(_boxText(tester), isEmpty,
        reason: "receiver B's box must not show receiver A's address");
    expect(d.daemon.container.read(sendPreparationProvider).viaIp, isNull);
  });

  testWidgets('switching receiver adopts B\'s own remembered address, not A\'s',
      (tester) async {
    final d = await _boot(
      aAddresses: [trustedPeerAddress('10.0.0.1', 47808, 47808, 3000)],
      bAddresses: [trustedPeerAddress('192.168.5.5', 47808, 47808, 2500)],
    );
    addTearDown(d.daemon.dispose);

    final file = _makeFile('privet-via-switch-adopt');
    await _pumpOnA(tester, d.daemon, file);
    expect(_boxText(tester), '10.0.0.1');

    d.daemon.container
        .read(sendPreparationProvider.notifier)
        .setPeer(_fpB, name: 'bravo');
    await _settleFrames(tester);

    // B's newest remembered address is what the box shows and what is sent.
    expect(_boxText(tester), '192.168.5.5');
    expect(find.text('10.0.0.1'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);
    expect(d.sends.single!['via'], '192.168.5.5');
  });

  testWidgets('the suggestion chips list the current peer\'s addresses only',
      (tester) async {
    final d = await _boot(
      aAddresses: [
        trustedPeerAddress('10.0.0.1', 47808, 47808, 3000),
        trustedPeerAddress('10.0.0.2', 47808, 47808, 2000),
      ],
      bAddresses: [
        trustedPeerAddress('192.168.5.5', 47808, 47808, 2500),
        trustedPeerAddress('192.168.5.6', 47808, 47808, 1500),
      ],
    );
    addTearDown(d.daemon.dispose);

    final file = _makeFile('privet-via-switch-chips');
    await _pumpOnA(tester, d.daemon, file);
    expect(find.text('10.0.0.2'), findsOneWidget);

    d.daemon.container
        .read(sendPreparationProvider.notifier)
        .setPeer(_fpB, name: 'bravo');
    await _settleFrames(tester);

    // The chips are `remembered: selectedPeer?.addresses`; they must be B's.
    expect(find.text('192.168.5.6'), findsOneWidget);
    expect(find.text('10.0.0.2'), findsNothing,
        reason: "a previous receiver's address must not be offered as a choice");
  });

  testWidgets('an address typed for A never reaches B, and does not come back',
      (tester) async {
    // A has nothing remembered, so the box starts empty and the typed text is
    // unmistakably the user's own.
    final d = await _boot(
      aAddresses: const [],
      bAddresses: const [],
    );
    addTearDown(d.daemon.dispose);

    final file = _makeFile('privet-via-switch-typed');
    await _pumpOnA(tester, d.daemon, file);

    await tester.enterText(
        find.byKey(const Key('via-address-field')), '172.16.0.9');
    await _settleFrames(tester);
    expect(d.daemon.container.read(sendPreparationProvider).viaIp, '172.16.0.9');

    final notifier = d.daemon.container.read(sendPreparationProvider.notifier);
    notifier.setPeer(_fpB, name: 'bravo');
    await _settleFrames(tester);

    // B must start from its own (empty) state.
    expect(_boxText(tester), isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);
    expect(d.sends.single!.containsKey('via'), isFalse,
        reason: 'the address typed for A must not be sent to B');

    // Coming back to A starts from A's own state, not the resurrected text.
    notifier.setPeer(_fpA, name: 'alpha');
    await _settleFrames(tester);
    expect(_boxText(tester), isEmpty,
        reason: 'A must re-seed from its own remembered addresses, not the old edit');
  });

  testWidgets('re-selecting the same receiver keeps a half-typed address',
      (tester) async {
    // Not a change of receiver: the user is still typing for the same device,
    // and a half-typed address is normal mid-edit.
    final d = await _boot(
      aAddresses: const [],
      bAddresses: const [],
    );
    addTearDown(d.daemon.dispose);

    final file = _makeFile('privet-via-same-peer');
    await _pumpOnA(tester, d.daemon, file);

    await tester.enterText(
        find.byKey(const Key('via-address-field')), '10.0.0');
    await _settleFrames(tester);
    expect(_boxText(tester), '10.0.0');
    expect(d.daemon.container.read(sendPreparationProvider).viaError, isNotNull);

    d.daemon.container
        .read(sendPreparationProvider.notifier)
        .setPeer(_fpA, name: 'alpha');
    await _settleFrames(tester);

    expect(_boxText(tester), '10.0.0',
        reason: 're-picking the same receiver is not a change of receiver');
  });

  testWidgets('the send-by-address entry keeps the address the user typed',
      (tester) async {
    // Regression pin: the send-by-address flow enters this page with a verified
    // address. That address is the one meant, and it must beat both the
    // remembered address and the "clear on receiver change" rule — the receiver
    // is set first, the address second.
    final d = await _boot(
      aAddresses: [trustedPeerAddress('10.0.0.1', 47808, 47808, 3000)],
      bAddresses: [trustedPeerAddress('192.168.5.5', 47808, 47808, 2500)],
    );
    addTearDown(d.daemon.dispose);

    final file = _makeFile('privet-via-entry');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: d.daemon.container,
      child: MaterialApp(
        home: SendPreparationPage(
          initialEntries: [
            SendFileEntry(path: file, relativePath: 'a.txt', size: 5),
          ],
          initialPeerFingerprint: _fpB,
          initialPeerName: 'bravo',
          initialViaIp: '172.20.9.9',
        ),
      ),
    ));
    await _settleFrames(tester);

    // The typed address wins over B's remembered 192.168.5.5.
    expect(_boxText(tester), '172.20.9.9');
    expect(d.daemon.container.read(sendPreparationProvider).viaIp, '172.20.9.9');

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);
    expect(d.sends.single!['via'], '172.20.9.9');
  });

  test('clearing the receiver clears the address too', () async {
    final d = await _boot(
      aAddresses: [trustedPeerAddress('10.0.0.1', 47808, 47808, 3000)],
      bAddresses: const [],
    );
    addTearDown(d.daemon.dispose);

    final n = d.daemon.container.read(sendPreparationProvider.notifier)
      ..addFileEntry(
          SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1))
      ..setPeer(_fpA, name: 'alpha')
      ..setVia('172.16.0.9');

    expect(n.state.viaIp, '172.16.0.9');

    n.clearPeer();
    expect(n.state.peerFingerprint, isNull);
    expect(n.state.viaIp, isNull,
        reason: 'an address with no receiver is an address for nobody');
  });

  test('a receiver change clears a pending address error as well', () async {
    final d = await _boot(
      aAddresses: const [],
      bAddresses: const [],
    );
    addTearDown(d.daemon.dispose);

    final n = d.daemon.container.read(sendPreparationProvider.notifier)
      ..addFileEntry(
          SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1))
      ..setPeer(_fpA, name: 'alpha')
      ..setVia('not-an-ip');

    expect(n.state.viaError, isNotNull);
    expect(n.state.isReady, isFalse);

    // B is a different device; A's typo says nothing about B and must not
    // leave B's send disabled.
    n.setPeer(_fpB, name: 'bravo');
    expect(n.state.viaError, isNull);
    expect(n.state.viaIp, isNull);
    expect(n.state.isReady, isTrue);
  });
}