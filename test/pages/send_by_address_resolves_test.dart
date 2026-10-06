// "Send by Address" must tell two situations apart, and it can: a device this
// daemon already trusts carries the addresses it has been reached at (pairing
// records one; every completed transfer re-records one). So an address that
// matches a trusted device is a *send* -- the address becomes the explicit
// `via` target -- and only an address that matches nothing falls through to the
// pairing-code flow.
//
// Regression: the entry used to jump straight to Pair by Address, so a device
// that was already paired was asked for a pairing code it had already
// exchanged, every single time.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/send_preparation_page.dart';
import 'package:privet_app/providers/peers.dart';
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

/// One real file on disk; testWidgets' FakeAsync zone never completes awaited
/// disk I/O, so every disk touch here is synchronous.
String _makeFile(String dirName) {
  final dir = Directory('${Directory.systemTemp.path}/$dirName')
    ..createSync(recursive: true);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return (File('${dir.path}/a.txt')..writeAsStringSync('hello')).path;
}

/// Drives the UI path under test: recipient "Change" -> "Send by Address" ->
/// type [address] -> Next.
Future<void> _sendByAddress(WidgetTester tester, String address) async {
  await tester.tap(find.text('Change'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Send by Address'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), address);
  await tester.tap(find.text('Next'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an address of an already-paired device sends, without a code',
      (tester) async {
    var pairCalled = false;
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_trusted': (id, _) => listTrustedResponse(id, [
            trustedPeer('fp-phone',
                name: 'phone',
                addresses: [
                  trustedPeerAddress('10.29.252.2', 47808, 47808, 3000),
                ]),
          ]),
      'pair': (id, _) {
        pairCalled = true;
        return okResponse(id, 'pairing_result', {
          'paired': true,
          'device_fingerprint': 'fp-phone',
        });
      },
    }));
    addTearDown(daemon.dispose);

    final file = _makeFile('privet-send-by-address-known');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: SendPreparationPage(
          initialEntries: [
            SendFileEntry(path: file, relativePath: 'a.txt', size: 5),
          ],
        ),
      ),
    ));
    await _settleFrames(tester);

    await _sendByAddress(tester, '10.29.252.2');

    // No pairing was attempted, and no code was requested.
    expect(pairCalled, isFalse);
    expect(find.text('Enter Pairing Code'), findsNothing);

    // The recipient is the trusted device, and the typed address is pinned as
    // the dial target.
    final state = daemon.container.read(sendPreparationProvider);
    expect(state.peerFingerprint, 'fp-phone');
    expect(state.peerName, 'phone');
    expect(state.viaIp, '10.29.252.2');
    expect(state.viaError, isNull);
  });

  testWidgets('an address no trusted device remembers still pairs',
      (tester) async {
    var pairCalled = false;
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      // A trusted device whose remembered address is a *different* one: the
      // typed address belongs to nobody we know, so the code is the only way to
      // learn who is there.
      'list_trusted': (id, _) => listTrustedResponse(id, [
            trustedPeer('fp-phone',
                name: 'phone',
                addresses: [
                  trustedPeerAddress('10.29.252.2', 47808, 47808, 3000),
                ]),
          ]),
      'pair': (id, _) {
        pairCalled = true;
        return okResponse(id, 'pairing_result', {
          'paired': true,
          'device_fingerprint': 'fp-new',
        });
      },
    }));
    addTearDown(daemon.dispose);

    final file = _makeFile('privet-send-by-address-unknown');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: SendPreparationPage(
          initialEntries: [
            SendFileEntry(path: file, relativePath: 'a.txt', size: 5),
          ],
        ),
      ),
    ));
    await _settleFrames(tester);

    await _sendByAddress(tester, '10.29.9.9');

    // The pairing-code dialog is the expected outcome here, and nothing has
    // been paired yet.
    expect(find.text('Enter Pairing Code'), findsOneWidget);
    expect(pairCalled, isFalse);
    expect(daemon.container.read(sendPreparationProvider).viaIp, isNull);
  });

  testWidgets('a trusted device broadcasting an unrecorded address sends too',
      (tester) async {
    // The trust record may not have the address yet (a device that moved
    // networks, or one paired before addresses were kept), but discovery can see
    // it on the air. That is still a device we already have, so it must not be
    // sent back through pairing either.
    var pairCalled = false;
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_trusted': (id, _) => listTrustedResponse(id, [
            trustedPeer('fp-phone', name: 'phone'),
          ]),
      'list_peers': (id, _) => okResponse(id, 'peers', [
            {
              'device_fingerprint': 'fp-phone',
              'device_name': 'phone',
              'state': 'seen',
              'last_beacon_ms': 0,
              'candidates': [
                trustedPeerAddress('10.29.252.2', 47808, 47808, 1),
              ],
            },
          ]),
      'pair': (id, _) {
        pairCalled = true;
        return okResponse(id, 'pairing_result', {
          'paired': true,
          'device_fingerprint': 'fp-phone',
        });
      },
    }));
    addTearDown(daemon.dispose);
    await daemon.container.read(peerListProvider.notifier).refresh();

    final file = _makeFile('privet-send-by-address-discovered');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: SendPreparationPage(
          initialEntries: [
            SendFileEntry(path: file, relativePath: 'a.txt', size: 5),
          ],
        ),
      ),
    ));
    await _settleFrames(tester);

    await _sendByAddress(tester, '10.29.252.2');

    expect(pairCalled, isFalse);
    expect(find.text('Enter Pairing Code'), findsNothing);
    final state = daemon.container.read(sendPreparationProvider);
    expect(state.peerFingerprint, 'fp-phone');
    expect(state.viaIp, '10.29.252.2');
  });
}
