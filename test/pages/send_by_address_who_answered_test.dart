// What "Send by Address" shows when a device answers the typed address.
//
// The case this exists for: the user dials an address, a device answers, and
// the flow falls through to a pairing-code prompt. On its own that prompt is a
// blind end — six empty digits and no hint of who is on the other end — so a
// device the user already paired (on another network, at an address this one
// never recorded) is indistinguishable from a stranger, and the user cannot
// tell "this really is a different identity" apart from "the fix did not work".
//
// These tests pin the observable difference between the four outcomes, using
// payloads captured from a real daemon rather than invented ones.
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

/// The address from the report this change answers: a device answered there,
/// and the user believed it was one they had already paired.
const _reportedAddress = '10.29.218.79';

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
/// has to answer it even when the send-by-address flow never reads it.
List<Map<String, dynamic>> Function(List<Map<String, dynamic>>) _script(
    Map<String, Map<String, dynamic> Function(String id, Map<String, dynamic> params)>
        handlers) {
  return scriptFromHandlers({
    'get_identity': (id, _) => okResponse(id, 'identity', _identity),
    'get_runtime_config': (id, _) =>
        okResponse(id, 'runtime_config', _runtimeConfig),
    'list_trusted': (id, _) => listTrustedResponse(id, []),
    ...handlers,
  });
}

/// An IPC-level failure (the daemon refused the call), which is what
/// `resolve_address` raises rather than an answer with `found: false`.
Map<String, dynamic> _errorResponse(String id, String code, String message) =>
    serverMessage('response', {
      'request_id': id,
      'error': {'code': code, 'message': message},
    });

/// A daemon answering that nothing is there. [deviceFingerprint] and
/// [deviceName] are null exactly when `found` is false.
Map<String, dynamic> _notFoundPayload() => {
      'found': false,
      'device_fingerprint': null,
      'device_name': null,
      'trusted': false,
      'quic_port': 47808,
      'tcp_port': 47808,
    };

/// The pairing-code prompt, by its title. Asserted absent wherever the flow
/// must *not* fall back to pairing.
final _pairingCodeDialog = find.text('Enter Pairing Code');

void main() {
  group('who answered the address', () {
    testWidgets(
        'a device already in the trust store is named by the send itself, '
        'with no code and no extra step', (tester) async {
      // The trusted branch must stay exactly as short as it was: naming the
      // device here would add a tap for the common case to fix a prompt the
      // user only ever reaches for the uncommon one.
      var pairCalled = false;
      final daemon = await bootTestDaemon(_script({
        'resolve_address': (id, _) =>
            okResponse(id, 'resolved_address', resolveTrustedPayload()),
        'pair': (id, _) {
          pairCalled = true;
          return okResponse(id, 'pairing_result', {'paired': true});
        },
      }));
      addTearDown(daemon.dispose);

      await _pumpPage(tester, daemon, 'privet-who-answered-trusted');
      await _sendByAddress(tester, _reportedAddress);

      expect(_pairingCodeDialog, findsNothing);
      expect(find.textContaining('not paired'), findsNothing);
      expect(pairCalled, isFalse);

      final state = daemon.container.read(sendPreparationProvider);
      expect(state.peerFingerprint,
          '828312c176632a80f48fa41e57e48655af6d97a838e86b9a6ffd9eb7f374feac');
      expect(state.viaIp, _reportedAddress);
      expect(state.viaError, isNull);
    });

    testWidgets(
        'an untrusted answerer is named on screen before any code is asked '
        'for', (tester) async {
      // The regression this pins: the prompt used to appear with nothing in it
      // but a code field, so the user could not check the answerer against
      // Known Devices and had to assume. All four facts — who, which identity,
      // where, and that it is not paired — have to be on that one screen.
      var pairCalled = false;
      final daemon = await bootTestDaemon(_script({
        'resolve_address': (id, _) =>
            okResponse(id, 'resolved_address', resolveUntrustedPayload()),
        'pair': (id, _) {
          pairCalled = true;
          return okResponse(id, 'pairing_result', {'paired': true});
        },
      }));
      addTearDown(daemon.dispose);

      await _pumpPage(tester, daemon, 'privet-who-answered-untrusted');
      await _sendByAddress(tester, _reportedAddress);

      // The prompt is still a pairing prompt — naming the device must not turn
      // a pairing into a send.
      expect(_pairingCodeDialog, findsOneWidget);
      expect(pairCalled, isFalse);

      // Who it is, checkable against the Known Devices list: the name and the
      // head and tail of the fingerprint, not the whole 64-character hex.
      expect(find.textContaining('Thinkpad-P15v-LXR'), findsOneWidget);
      expect(find.textContaining('89507b08…e0a0'), findsOneWidget);

      // Where it answered, and that this device does not know it.
      expect(find.textContaining(_reportedAddress), findsOneWidget);
      expect(find.textContaining('not paired'), findsOneWidget);

      // One screen carries all of it, so the user is not sent looking for the
      // second half of the answer somewhere else.
      final notice = describeUnpairedAnswerer(
        name: 'Thinkpad-P15v-LXR',
        fingerprint:
            '89507b08f8f34d7bb77a7b241ebefbe3a037d6c9d33a934e597af93249a6e0a0',
        address: _reportedAddress,
      );
      expect(find.text(notice), findsOneWidget);

      // Nothing was paired and no recipient was silently chosen.
      final state = daemon.container.read(sendPreparationProvider);
      expect(state.peerFingerprint, isNull);
      expect(state.viaIp, isNull);
    });

    testWidgets('an address nothing answers names nobody and pairs nobody',
        (tester) async {
      var pairCalled = false;
      final daemon = await bootTestDaemon(_script({
        'resolve_address': (id, _) =>
            okResponse(id, 'resolved_address', _notFoundPayload()),
        'pair': (id, _) {
          pairCalled = true;
          return okResponse(id, 'pairing_result', {'paired': false});
        },
      }));
      addTearDown(daemon.dispose);

      await _pumpPage(tester, daemon, 'privet-who-answered-silent');
      await _sendByAddress(tester, _reportedAddress);

      expect(_pairingCodeDialog, findsNothing);
      expect(pairCalled, isFalse);
      expect(find.textContaining('No device answered'), findsOneWidget);
      // With no answer there is no identity to show, and inventing one would be
      // worse than saying nothing.
      expect(find.textContaining('not paired'), findsNothing);

      final state = daemon.container.read(sendPreparationProvider);
      expect(state.peerFingerprint, isNull);
      expect(state.viaIp, isNull);
    });

    testWidgets(
        'a failing resolve_address reports and never falls back to pairing',
        (tester) async {
      // The dangerous failure mode is not the error message but the reaction
      // to it: dropping into pairing would turn "the daemon could not tell me
      // who is there" into "type this device's code", which asks the user for a
      // secret to complete a lookup that already failed.
      var pairCalled = false;
      final daemon = await bootTestDaemon(_script({
        'resolve_address': (id, _) => _errorResponse(
            id, 'internal', 'resolve_address failed on the daemon side'),
        'pair': (id, _) {
          pairCalled = true;
          return okResponse(id, 'pairing_result', {'paired': true});
        },
      }));
      addTearDown(daemon.dispose);

      await _pumpPage(tester, daemon, 'privet-who-answered-error');
      await _sendByAddress(tester, _reportedAddress);

      // The absence of the prompt is the point here, and it is asserted
      // directly rather than inferred from the absence of a pairing.
      expect(_pairingCodeDialog, findsNothing);
      expect(find.textContaining('Could not reach'), findsOneWidget);
      expect(pairCalled, isFalse);

      final state = daemon.container.read(sendPreparationProvider);
      expect(state.peerFingerprint, isNull);
      expect(state.viaIp, isNull);
    });
  });

  group('fingerprintHeadTail', () {
    test('keeps the first 8 and last 4, joined by an ellipsis', () {
      expect(
        fingerprintHeadTail(
            '89507b08f8f34d7bb77a7b241ebefbe3a037d6c9d33a934e597af93249a6e0a0'),
        '89507b08…e0a0',
      );
    });

    test('shows a fingerprint too short to trim whole', () {
      // Trimming 12 characters would leave nothing but ellipses, which reads as
      // a rendering bug rather than as a short fingerprint.
      expect(fingerprintHeadTail('89507b08e0a0'), '89507b08e0a0');
      expect(fingerprintHeadTail(''), '');
    });
  });

  group('describeUnpairedAnswerer', () {
    test('names the device, the address, and the fact it is not paired', () {
      expect(
        describeUnpairedAnswerer(
          name: 'Thinkpad-P15v-LXR',
          fingerprint:
              '89507b08f8f34d7bb77a7b241ebefbe3a037d6c9d33a934e597af93249a6e0a0',
          address: '10.29.218.79',
        ),
        'Thinkpad-P15v-LXR (89507b08…e0a0) answered at 10.29.218.79 '
        'but is not paired with this device.',
      );
    });

    test('omits an empty fingerprint rather than printing empty brackets', () {
      expect(
        describeUnpairedAnswerer(
            name: 'unknown device', fingerprint: null, address: '10.29.218.79'),
        'unknown device answered at 10.29.218.79 '
        'but is not paired with this device.',
      );
    });
  });
}