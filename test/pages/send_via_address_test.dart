// The send page's "address" box is the user-facing half of the `via` feature:
// it lets someone reach a device that cannot be discovered (campus AP with
// client isolation, a beacon-blocking VLAN), and it is pre-filled with the
// address the daemon remembered so the common case needs no typing.
//
// These tests cover the rendering contract: the box appears for a trusted
// recipient, shows the newest remembered address, offers the older ones, and
// keeps a bad address from being sent.
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

/// Creates one real file on disk and returns its path. testWidgets runs in a
/// FakeAsync zone where awaiting real disk I/O never completes, so every disk
/// touch here is synchronous.
String _makeFile(String dirName) {
  final dir = Directory('${Directory.systemTemp.path}/$dirName')
    ..createSync(recursive: true);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final file = File('${dir.path}/a.txt')..writeAsStringSync('hello');
  return file.path;
}

void main() {
  testWidgets('pre-fills the newest remembered address and shows the older ones',
      (tester) async {
    var sendCalled = false;
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_trusted': (id, _) => listTrustedResponse(id, [
            trustedPeer('trusted-fp', addresses: [
              trustedPeerAddress('10.29.210.120', 47808, 47808, 3000),
              trustedPeerAddress('192.168.1.7', 47808, 47810, 2000),
              trustedPeerAddress('fe80::1c2b:3d4e', 47808, 47808, 1000),
            ]),
          ]),
      // The page probes the selected receiver's remembered address once on
      // entry, because its reachability verdict reads the same input the home
      // page does. This test is about the box, not about whether the address
      // answers, so "nobody is there" is the neutral answer.
      'resolve_address': (id, _) => resolveNotFoundResponse(id),
      'send': (id, params) {
        sendCalled = true;
        return okResponse(id, 'transfer_queued', {'transfer_id': 't-via'});
      },
    }));
    addTearDown(daemon.dispose);

    final file = _makeFile('privet-via-prefill');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: SendPreparationPage(
          initialEntries: [
            SendFileEntry(path: file, relativePath: 'a.txt', size: 5),
          ],
          initialPeerFingerprint: 'trusted-fp',
          initialPeerName: 'friend',
        ),
      ),
    ));
    await _settleFrames(tester);

    // The box is pre-filled with the newest remembered address, and the older
    // ones are offered so a different interface can be picked without typing.
    expect(find.text('10.29.210.120'), findsWidgets);
    expect(find.text('192.168.1.7'), findsOneWidget);
    expect(find.text('fe80::1c2b:3d4e'), findsOneWidget);

    // The remembered address is used as-is, without a port: the engine takes
    // the port from the device record.
    final state = daemon.container.read(sendPreparationProvider);
    expect(state.viaIp, '10.29.210.120');
    expect(state.viaError, isNull);
    expect(sendCalled, isFalse);
  });

  testWidgets('sending to an offline device works when an address is pinned',
      (tester) async {
    // This is the whole point of the feature: a device that cannot be
    // discovered is permanently "offline" while still reachable by IP, so the
    // offline gate must not block the send once an address is set.
    Map<String, dynamic>? sent;
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_trusted': (id, _) => listTrustedResponse(id, [
            trustedPeer('trusted-fp',
                addresses: [trustedPeerAddress('10.29.210.120', 47808, 47808, 3000)]),
          ]),
      'resolve_address': (id, _) => resolveNotFoundResponse(id),
      'send': (id, params) {
        sent = Map<String, dynamic>.from(params);
        return okResponse(id, 'transfer_queued', {'transfer_id': 't-off'});
      },
    }));
    addTearDown(daemon.dispose);

    final file = _makeFile('privet-via-offline');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: SendPreparationPage(
          initialEntries: [
            SendFileEntry(path: file, relativePath: 'a.txt', size: 5),
          ],
          initialPeerFingerprint: 'trusted-fp',
          initialPeerName: 'friend',
        ),
      ),
    ));
    await _settleFrames(tester);

    // 'friend' never broadcasts and its address did not answer, so the page
    // says exactly that — naming the address it tried — instead of the old
    // "not discoverable" wording, which asserted a cause the probe never
    // established. The pinned address still lets the send through.
    expect(find.textContaining('is offline'), findsNothing);
    expect(find.textContaining('No answer at 10.29.210.120'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);

    expect(sent, isNotNull, reason: 'an explicit address must be allowed to send');
    expect(sent!['via'], '10.29.210.120');
    expect(tester.takeException(), isNull);
  });

  testWidgets('an invalid address blocks the send with a clear error',
      (tester) async {
    var sendCalled = false;
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_trusted': (id, _) => listTrustedResponse(id, [
            // No remembered address: the box starts empty and the user types a
            // bad one themselves.
            trustedPeer('trusted-fp'),
          ]),
      'send': (id, _) {
        sendCalled = true;
        return okResponse(id, 'transfer_queued', {'transfer_id': 't-x'});
      },
    }));
    addTearDown(daemon.dispose);

    final file = _makeFile('privet-via-invalid');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: SendPreparationPage(
          initialEntries: [
            SendFileEntry(path: file, relativePath: 'a.txt', size: 5),
          ],
          initialPeerFingerprint: 'trusted-fp',
          initialPeerName: 'friend',
        ),
      ),
    ));
    await _settleFrames(tester);

    await tester.enterText(
        find.byKey(const Key('via-address-field')), 'not-an-ip');
    await _settleFrames(tester);

    // The error is shown and the daemon is never contacted: a request with a
    // malformed `via` is refused before queueing, so sending it is pointless.
    expect(find.textContaining('is not a valid IP address'), findsOneWidget);
    final state = daemon.container.read(sendPreparationProvider);
    expect(state.viaError, isNotNull);
    expect(state.viaIp, isNull);

    final sendButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Send'));
    expect(sendButton.onPressed, isNull, reason: 'send must be disabled');

    expect(sendCalled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a port typed into the box is stripped before sending',
      (tester) async {
    Map<String, dynamic>? sent;
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_trusted': (id, _) => listTrustedResponse(id, [
            trustedPeer('trusted-fp'),
          ]),
      'send': (id, params) {
        sent = Map<String, dynamic>.from(params);
        return okResponse(id, 'transfer_queued', {'transfer_id': 't-p'});
      },
    }));
    addTearDown(daemon.dispose);

    final file = _makeFile('privet-via-port');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: SendPreparationPage(
          initialEntries: [
            SendFileEntry(path: file, relativePath: 'a.txt', size: 5),
          ],
          initialPeerFingerprint: 'trusted-fp',
          initialPeerName: 'friend',
        ),
      ),
    ));
    await _settleFrames(tester);

    await tester.enterText(
        find.byKey(const Key('via-address-field')),
        '10.29.210.120:47808');
    await _settleFrames(tester);

    // Accepted (not an error) and reduced to the bare IP for the engine.
    final state = daemon.container.read(sendPreparationProvider);
    expect(state.viaError, isNull);
    expect(state.viaIp, '10.29.210.120');

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);
    expect(sent!['via'], '10.29.210.120');
  });

  testWidgets('a daemon without remembered addresses still shows the box',
      (tester) async {
    // `addresses` is an additive field: a daemon predating it omits the key
    // entirely. The box must still be usable, just empty.
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_trusted': (id, _) => listTrustedResponse(id, [
            trustedPeer('trusted-fp'),
          ]),
    }));
    addTearDown(daemon.dispose);

    final file = _makeFile('privet-via-old-daemon');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: SendPreparationPage(
          initialEntries: [
            SendFileEntry(path: file, relativePath: 'a.txt', size: 5),
          ],
          initialPeerFingerprint: 'trusted-fp',
          initialPeerName: 'friend',
        ),
      ),
    ));
    await _settleFrames(tester);

    final state = daemon.container.read(sendPreparationProvider);
    expect(state.viaIp, isNull);
    expect(state.viaError, isNull);
    // Nothing was pre-filled, so the empty box must not be blocking anything.
    expect(find.text('Send to address'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
