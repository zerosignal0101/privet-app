// Desktop has no pull-to-refresh touch gesture, so the Home AppBar shows a
// refresh button (kept alongside the pull-down for touch devices). It must
// refresh both "Nearby Devices" (the discovery peer list) and "Known Devices"
// (the trusted list) — the pull-down only re-scanned discovery, leaving the
// known-device list stale.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/home_page.dart';

import '../support/test_daemon.dart';

void main() {
  testWidgets('Home refresh button re-reads peers and trusted devices',
      (tester) async {
    var peersCalls = 0;
    var trustedCalls = 0;
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
      'list_peers': (id, _) {
        peersCalls++;
        return okResponse(id, 'peers', [
          {
            'device_fingerprint': 'nearby-1',
            'device_name': 'nearby',
            'state': 'seen',
            'last_beacon_ms': 0,
            'candidates': <dynamic>[],
          },
        ]);
      },
      'list_trusted': (id, _) {
        trustedCalls++;
        return okResponse(id, 'trusted', [
          {
            'device_fingerprint': 'trusted-1',
            'device_name': 'friend',
            'trust_state': 'Trusted',
            'spki_hex': 'x',
            'first_paired_ts': 1,
            'last_seen_ts': 2,
            'revoked_ts': null,
            'revocation_reason': null,
          },
        ]);
      },
    }));
    addTearDown(daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pumpAndSettle();

    // The trusted list loads on build (FutureProvider fetch); the peer list
    // starts empty and only populates on a scan (refresh / events).
    expect(find.text('friend'), findsOneWidget); // Known Devices
    expect(find.text('nearby'), findsNothing); // not scanned yet

    // The AppBar refresh button is present.
    final refresh = find.widgetWithIcon(IconButton, Icons.refresh);
    expect(refresh, findsOneWidget);

    final beforePeers = peersCalls;
    final beforeTrusted = trustedCalls;
    await tester.tap(refresh);
    await tester.pumpAndSettle();

    // The one button re-fetched both providers: nearby devices now appear and
    // the trusted list was re-read from the daemon.
    expect(peersCalls, greaterThan(beforePeers));
    expect(trustedCalls, greaterThan(beforeTrusted));
    expect(find.text('nearby'), findsOneWidget); // Nearby Devices

    // UncontrolledProviderScope does not own the container; dispose it before
    // the test ends so activeTransfersProvider's periodic reconcile timer is
    // cancelled (otherwise the framework fails on the pending timer).
    daemon.dispose();
  });
}
