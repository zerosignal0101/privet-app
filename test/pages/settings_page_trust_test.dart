// Settings' trusted-devices management must (a) un-pair via `forget_peer`, not
// `revoke_peer` — revoking leaves a `Revoked` row that the daemon hard-rejects
// on reconnect, which surfaced as "Pairing failed: quic read: connection lost"
// when the user scanned a QR after removing trust — and (b) surface revoked
// devices so a previously-banned device can be forgotten and paired again.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_daemon.dart';

void main() {
  testWidgets('Remove Trust forgets; revoked devices stay recoverable',
      (tester) async {
    SharedPreferences.setMockInitialValues({});

    final forgetCalls = <String>[];
    final revokeCalls = <String>[];
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', {
            'device_fingerprint': 'me',
            'device_name': 'mydev',
          }),
      'get_runtime_config': (id, _) => okResponse(id, 'runtime_config', {
            'accept_all_trusted': false,
            'collision_policy': 'rename',
            'save_dir': 'C:\\received',
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
            {
              'device_fingerprint': 'revoked-fp',
              'device_name': 'ex',
              'trust_state': 'Revoked',
              'spki_hex': 'y',
              'first_paired_ts': 3,
              'last_seen_ts': 4,
              'revoked_ts': 5,
              'revocation_reason': 'user_request',
            },
          ]),
      'forget_peer': (id, params) {
        forgetCalls.add(params['device_fingerprint'] as String);
        return okResponse(id, 'ack', null);
      },
      'revoke_peer': (id, params) {
        revokeCalls.add(params['device_fingerprint'] as String);
        return okResponse(id, 'ack', null);
      },
    }));
    addTearDown(daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: const MaterialApp(home: SettingsPage()),
    ));
    await tester.pumpAndSettle();

    // A tall surface so the lazy ListView builds the revoked section too.
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    // Trusted and revoked devices are both shown (revoked under their own
    // section so a banned device can be cleared).
    expect(find.text('friend'), findsOneWidget);
    expect(find.text('ex'), findsOneWidget);
    expect(find.text('Revoked Devices'), findsOneWidget);

    // Removing a trusted device calls forget_peer, never revoke_peer.
    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'friend'),
      matching: find.byIcon(Icons.delete_outline),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Remove Trust?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(forgetCalls, ['trusted-fp']);
    expect(revokeCalls, isEmpty);

    // Forgetting a revoked device also uses forget_peer, so it becomes unknown
    // again and can pair fresh.
    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'ex'),
      matching: find.byIcon(Icons.delete_outline),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Forget'));
    await tester.pumpAndSettle();

    expect(forgetCalls, ['trusted-fp', 'revoked-fp']);
    expect(revokeCalls, isEmpty);

    // UncontrolledProviderScope does not own the container; dispose it so
    // activeTransfersProvider's periodic reconcile timer is cancelled.
    daemon.dispose();
  });
}
