// Sending to a Known Device that is not currently broadcasting must not hit the
// daemon (which would spin against a dead address into an "Internal Error" tile
// or a bare Failed history row). The send page marks the recipient offline and
// surfaces a clear error instead.
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
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('send to an offline recipient shows a clear error and is blocked',
      (tester) async {
    var sendCalled = false;
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', {
            'device_fingerprint': 'me',
            'device_name': 'mydev',
          }),
      'get_runtime_config': (id, _) => okResponse(id, 'runtime_config', {
            'accept_all_trusted': false,
            'collision_policy': 'rename',
            'save_dir': r'C:\received',
          }),
      'list_trusted': (id, _) => okResponse(id, 'trusted', [
            {
              'device_fingerprint': 'trusted-fp',
              'device_name': 'friend',
              'trust_state': 'Trusted',
              'spki_hex': 'x',
              'first_paired_ts': 1,
              'last_seen_ts': 2,
              'revoked_ts': null,
              'revocation_reason': null,
            },
          ]),
      'send': (id, _) {
        sendCalled = true;
        return okResponse(id, 'transfer_queued', {'transfer_id': 't-x'});
      },
    }));
    addTearDown(daemon.dispose);

    // Synchronous disk setup: testWidgets runs in a FakeAsync zone where
    // awaiting real disk I/O never completes.
    final dir = Directory('${Directory.systemTemp.path}/privet-offline-send')
      ..createSync(recursive: true);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File('${dir.path}/a.txt')..writeAsStringSync('hello');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: SendPreparationPage(
          initialEntries: [
            SendFileEntry(path: file.path, relativePath: 'a.txt', size: 5),
          ],
          initialPeerFingerprint: 'trusted-fp',
          initialPeerName: 'friend',
        ),
      ),
    ));
    await _settleFrames(tester);

    // 'friend' is trusted but has not broadcast -> clearly marked offline.
    expect(find.textContaining('is offline'), findsWidgets);

    // Pressing Send must not call the daemon.
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);

    expect(sendCalled, isFalse,
        reason: 'an offline recipient must never reach the daemon');
    expect(find.textContaining("can't receive files"), findsOneWidget);
    expect(tester.takeException(), isNull);

    // UncontrolledProviderScope does not own the container; dispose it.
    daemon.dispose();
  });
}
