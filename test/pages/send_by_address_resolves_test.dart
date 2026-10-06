// "Send by Address" must tell three situations apart, and it does so by dialling:
// the daemon completes the identity handshake pairing performs *before* it asks
// for a code, so the address itself is resolved to a device.
//
// That matters most for the case a local lookup cannot cover: a device paired on
// one network and met again on another is at an address nothing here has ever
// recorded, and is not discoverable either. Matching the typed address against
// remembered addresses would find nothing and send the user back through pairing
// for a device they already have.
//
// Regression: the entry used to jump straight to Pair by Address, so an already
// paired device was asked for a code it had already exchanged, every time.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/send_preparation_page.dart';
import 'package:privet_app/providers/send_preparation.dart';

import '../support/resolve_fixtures.dart';
import '../support/test_daemon.dart';

/// Bounded pump helper: enough frames for the providers the page reads on build
/// to resolve without waiting on an unbounded settle.
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

/// The `resolve_address` answer for a device this daemon already has, as a real
/// daemon actually sent it.
Map<String, dynamic> _resolvedTrusted() => resolveTrustedPayload();

/// The `resolve_address` answer for something that answered but is unknown,
/// likewise a real capture.
Map<String, dynamic> _resolvedStranger() => resolveUntrustedPayload();

/// The Xiaomi from the real trusted capture.
const _trustedFingerprint =
    '828312c176632a80f48fa41e57e48655af6d97a838e86b9a6ffd9eb7f374feac';
const _trustedName = 'Xiaomi 2410DPN6CC LXR';

/// The ThinkPad from the real untrusted capture.
const _strangerFingerprint =
    '89507b08f8f34d7bb77a7b241ebefbe3a037d6c9d33a934e597af93249a6e0a0';

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

Future<void> _pumpPage(
    WidgetTester tester, TestDaemon daemon, String fileName) async {
  final file = _makeFile(fileName);
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
}

/// The page watches `list_trusted` for the recipient display, so every script
/// has to answer it even when the send-by-address flow never reads it. A test
/// that needs real rows overrides it in its own [handlers].
List<Map<String, dynamic>> Function(List<Map<String, dynamic>>) _script(
    Map<String, Map<String, dynamic> Function(String id, Map<String, dynamic> params)>
        handlers) {
  return scriptFromHandlers({
    'list_trusted': (id, _) => listTrustedResponse(id, []),
    ...handlers,
  });
}

void main() {
  testWidgets('an address of an already-paired device sends, without a code',
      (tester) async {
    var pairCalled = false;
    Map<String, dynamic>? resolveParams;
    final daemon = await bootTestDaemon(_script({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'resolve_address': (id, params) {
        resolveParams = params;
        return okResponse(id, 'resolved_address', _resolvedTrusted());
      },
      'pair': (id, _) {
        pairCalled = true;
        return okResponse(id, 'pairing_result', {
          'paired': true,
          'device_fingerprint': _trustedFingerprint,
        });
      },
    }));
    addTearDown(daemon.dispose);

    await _pumpPage(tester, daemon, 'privet-send-by-address-known');
    await _sendByAddress(tester, '10.29.252.2');

    // The address was dialled, and only the address: no port travels with it
    // when the user did not type one, so the daemon dials its own listener
    // ports rather than a literal the user never chose.
    expect(resolveParams?['ip'], '10.29.252.2');
    expect(resolveParams?['quic_port'], isNull);
    expect(resolveParams?['tcp_port'], isNull);

    // No pairing was attempted, and no code was requested.
    expect(pairCalled, isFalse);
    expect(find.text('Enter Pairing Code'), findsNothing);

    // The recipient is the device that answered, and the typed address is pinned
    // as the dial target.
    final state = daemon.container.read(sendPreparationProvider);
    expect(state.peerFingerprint, _trustedFingerprint);
    expect(state.peerName, _trustedName);
    expect(state.viaIp, '10.29.252.2');
    expect(state.viaError, isNull);
  });

  testWidgets('a device paired on another network sends at its new address',
      (tester) async {
    // The case this path exists for: the trust store remembers the address the
    // device was paired at (here, a home network), and the user is now somewhere
    // else holding only the address they just read off the other screen. A
    // remembered-address lookup finds nothing; the dial finds the device.
    var pairCalled = false;
    final daemon = await bootTestDaemon(_script({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_trusted': (id, _) => listTrustedResponse(id, [
            trustedPeer(_trustedFingerprint,
                name: _trustedName,
                addresses: [
                  // The old network — nothing in common with what was typed.
                  trustedPeerAddress('192.168.1.20', 47808, 47808, 3000),
                ]),
          ]),
      'resolve_address': (id, _) =>
          okResponse(id, 'resolved_address', _resolvedTrusted()),
      'pair': (id, _) {
        pairCalled = true;
        return okResponse(id, 'pairing_result', {
          'paired': true,
          'device_fingerprint': _trustedFingerprint,
        });
      },
    }));
    addTearDown(daemon.dispose);

    await _pumpPage(tester, daemon, 'privet-send-by-address-moved');
    await _sendByAddress(tester, '10.29.218.79');

    expect(pairCalled, isFalse);
    expect(find.text('Enter Pairing Code'), findsNothing);
    final state = daemon.container.read(sendPreparationProvider);
    expect(state.peerFingerprint, _trustedFingerprint);
    expect(state.viaIp, '10.29.218.79');
  });

  testWidgets('an address that answers as an unknown device still pairs',
      (tester) async {
    var pairCalled = false;
    final daemon = await bootTestDaemon(_script({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'resolve_address': (id, _) =>
          okResponse(id, 'resolved_address', _resolvedStranger()),
      'pair': (id, _) {
        pairCalled = true;
        return okResponse(id, 'pairing_result', {
          'paired': true,
          'device_fingerprint': _strangerFingerprint,
        });
      },
    }));
    addTearDown(daemon.dispose);

    await _pumpPage(tester, daemon, 'privet-send-by-address-stranger');
    await _sendByAddress(tester, '10.29.9.9');

    // Something answered that this daemon does not have, so a code is the only
    // way to learn who it is: the pairing dialog is the expected outcome, and
    // nothing has been paired yet.
    expect(find.text('Enter Pairing Code'), findsOneWidget);
    expect(pairCalled, isFalse);
    expect(daemon.container.read(sendPreparationProvider).viaIp, isNull);
  });

  testWidgets('an address nothing answers at neither sends nor pairs',
      (tester) async {
    // "Nobody there" is an ordinary answer, not an error and not something to
    // pair with: pairing would fail in exactly the same way, so the user is told
    // what happened instead of being sent through a code exchange that cannot
    // succeed.
    var pairCalled = false;
    final daemon = await bootTestDaemon(_script({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'resolve_address': (id, _) => okResponse(id, 'resolved_address', {
            'found': false,
            'device_fingerprint': null,
            'device_name': null,
            'trusted': false,
            'quic_port': 47808,
            'tcp_port': 47808,
          }),
      'pair': (id, _) {
        pairCalled = true;
        return okResponse(id, 'pairing_result', {'paired': false});
      },
    }));
    addTearDown(daemon.dispose);

    await _pumpPage(tester, daemon, 'privet-send-by-address-silent');
    await _sendByAddress(tester, '10.29.7.7');

    expect(find.text('Enter Pairing Code'), findsNothing);
    expect(pairCalled, isFalse);
    expect(find.textContaining('No device answered'), findsOneWidget);
    final state = daemon.container.read(sendPreparationProvider);
    expect(state.peerFingerprint, isNull);
    expect(state.viaIp, isNull);
  });

  testWidgets('a typed port is passed on, an omitted one is not',
      (tester) async {
    // A port the user wrote is an instruction; the default the parser fills in
    // is not, and passing it would override the daemon's own listener ports with
    // a literal nobody chose.
    Map<String, dynamic>? resolveParams;
    final daemon = await bootTestDaemon(_script({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'resolve_address': (id, params) {
        resolveParams = params;
        return okResponse(id, 'resolved_address', _resolvedTrusted());
      },
    }));
    addTearDown(daemon.dispose);

    await _pumpPage(tester, daemon, 'privet-send-by-address-ported');
    await _sendByAddress(tester, '10.29.252.2:47999');

    expect(resolveParams?['ip'], '10.29.252.2');
    expect(resolveParams?['quic_port'], 47999);
    expect(resolveParams?['tcp_port'], 47999);
  });
}
