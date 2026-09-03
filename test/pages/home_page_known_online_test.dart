// Known Devices must show whether each device is currently online, and only
// offer a Send button for online ones — otherwise a user sends to an offline
// device and gets an opaque failure.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/home_page.dart';

import '../support/test_daemon.dart';

Map<String, dynamic> _discovered(
        int seq, String fp, String name) =>
    {'type': 'event', 'sequence': seq, 'event': {
      'name': 'device_discovered',
      'data': {'device_fingerprint': fp, 'device_name': name},
    }};

void main() {
  testWidgets('offline known device has no send button; online one does',
      (tester) async {
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
    }));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pumpAndSettle();

    final friendTile = find.widgetWithText(ListTile, 'friend');
    expect(friendTile, findsOneWidget);
    // Offline: no Send button, and the status is spelled out. The only Send
    // icon on screen is the floating action button.
    expect(find.textContaining('Offline'), findsOneWidget);
    final sendIconsBefore = find.byIcon(Icons.send).evaluate().length;
    expect(sendIconsBefore, 1,
        reason: 'an offline device must not offer a send button');
    expect(
        find.descendant(
            of: friendTile, matching: find.byIcon(Icons.send)),
        findsNothing);

    // The device starts broadcasting -> flips to Online with a Send button.
    daemon.transport.inject(
        _discovered(1, 'trusted-fp', 'friend'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Online'), findsOneWidget);
    expect(find.byIcon(Icons.send).evaluate().length,
        greaterThan(sendIconsBefore),
        reason: 'an online device must offer send');

    // The Known Devices tile that spells out "Online" carries its Send button.
    final onlineKnownTile = find.ancestor(
        of: find.textContaining('Online'), matching: find.byType(ListTile));
    expect(
        find.descendant(
            of: onlineKnownTile, matching: find.byIcon(Icons.send)),
        findsOneWidget);

    // UncontrolledProviderScope does not own the container; dispose it so the
    // periodic reconcile timer is cancelled before the pending-timer check.
    daemon.dispose();
  });
}
