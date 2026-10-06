// A trusted device that is not broadcasting must not be permanently greyed out
// just because its beacons do not reach this network.
//
// The engine remembers the address a successful send used (`addresses` on the
// trust record), so after a refresh the app probes that address and shows what
// it actually proved. These tests pin the four states and, above all, the guard
// that keeps a probed address from being mistaken for the device: a remembered
// IP can have been handed to a different machine, and treating "something
// answered" as "my friend is there" would offer a Send button that delivers
// files to a stranger.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/home_page.dart';
import 'package:privet_app/providers/peers.dart';
import 'package:privet_app/providers/send_preparation.dart';

import '../support/resolve_fixtures.dart';
import '../support/test_daemon.dart';

/// The fingerprint of the real device in `resolveTrustedJson` (a Xiaomi phone).
/// Using the fixture's own fingerprint is what makes "the same identity
/// answered" a fact about the fixture rather than an arbitrary string.
const _trustedFp = '828312c176632a80f48fa41e57e48655af6d97a838e86b9a6ffd9eb7f374feac';

const _identity = {
  'device_fingerprint': 'me',
  'device_name': 'mydev',
};
const _runtimeConfig = {
  'accept_all_trusted': false,
  'collision_policy': 'rename',
  'save_dir': r'C:\received',
};

/// The remembered address of [_trustedFp]: the IP a previous send used.
const _rememberedIp = '10.29.218.79';

/// A `list_peers` snapshot with [fp] broadcasting (state `seen`), i.e. online.
List<Map<String, dynamic>> _broadcasting(String fp, String name) => [
      {
        'device_fingerprint': fp,
        'device_name': name,
        'state': 'seen',
        'last_beacon_ms': 0,
        'candidates': <dynamic>[],
      },
    ];

/// Boots Home over a daemon whose trusted list holds [_trustedFp] with the
/// remembered address [_rememberedIp].
///
/// [peers] is what `list_peers` reports, [onResolve] answers `resolve_address`;
/// every `resolve_address` call is counted into [resolveCalls] so a test can
/// assert that a probe did — or did not — happen.
Future<({TestDaemon daemon, List<String> resolveCalls})> bootHome({
  required List<Map<String, dynamic>> peers,
  required Map<String, dynamic> Function(String id, Map<String, dynamic> params) onResolve,
  List<Map<String, dynamic>>? trusted,
  String fingerprint = _trustedFp,
  String name = 'Xiaomi 2410DPN6CC LXR',
  bool withAddress = true,
}) async {
  final resolveCalls = <String>[];
  final trustedRecord = trusted ??
      [
        trustedPeer(fingerprint,
            name: name,
            addresses: withAddress
                ? [trustedPeerAddress(_rememberedIp, 47808, 47808, 3000)]
                : null),
      ];
  final daemon = await bootTestDaemon(scriptFromHandlers({
    'get_identity': (id, _) => okResponse(id, 'identity', _identity),
    'get_runtime_config': (id, _) =>
        okResponse(id, 'runtime_config', _runtimeConfig),
    'list_peers': (id, _) => okResponse(id, 'peers', peers),
    'list_trusted': (id, _) => listTrustedResponse(id, trustedRecord),
    'resolve_address': (id, params) {
      resolveCalls.add(params['ip'] as String);
      return onResolve(id, params);
    },
  }));
  return (daemon: daemon, resolveCalls: resolveCalls);
}

/// Refreshes Home the way a user does — the AppBar button, which is the only
/// refresh on desktop — and waits for the probes it starts to finish.
Future<void> refreshHome(WidgetTester tester) async {
  await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
  await tester.pump();
  // Past the probe bound, so a hung daemon has been given up on and the spinner
  // has finished; pumpAndSettle alone would hang on a never-settling frame.
  await tester.pump(kReachabilityProbeTimeout + const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

/// The Known Devices row for [name].
///
/// Scoped to the first ListTile carrying the name: a device that is also
/// discovered shows up in Nearby Devices too, and the assertions here are about
/// the trusted row (which is the one that carries the remembered address).
Finder knownTile(String name) => find.widgetWithText(ListTile, name).first;

void main() {
  testWidgets(
      'a trusted device whose remembered address answers as itself is '
      'Reachable, offers Send, and sends via that address',
      (tester) async {
    // The address answers, and it answers as the same device the trusted row
    // is about — the real capture in resolve_fixtures.dart.
    final home = await bootHome(
      peers: const [],
      onResolve: (id, _) => okResponse(id, 'resolved_address', resolveTrustedPayload()),
    );
    addTearDown(home.daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: home.daemon.container,
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pumpAndSettle();

    // Before any refresh: no probe has run, so the row says only what
    // discovery knows.
    expect(find.textContaining('Offline'), findsOneWidget);

    await refreshHome(tester);

    // It really probed the remembered address — once, at that address.
    expect(home.resolveCalls, [_rememberedIp]);

    final tile = knownTile('Xiaomi 2410DPN6CC LXR');
    expect(tile, findsOneWidget);
    expect(find.textContaining('Reachable at $_rememberedIp'), findsOneWidget);
    // The address the engine remembered is visible on the row, so the user can
    // see what "Reachable at" refers to.
    expect(
        find.descendant(of: tile, matching: find.text(_rememberedIp)),
        findsOneWidget);
    // Not greyed out any more: Send is offered.
    expect(
        find.descendant(of: tile, matching: find.byIcon(Icons.send)),
        findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);

    // Sending from this row pins the address as `via`, which is the only thing
    // that can work for a device that is not on the air.
    await tester.tap(find.descendant(of: tile, matching: find.byIcon(Icons.send)));
    await tester.pumpAndSettle();

    final prep = home.daemon.container.read(sendPreparationProvider);
    expect(prep.peerFingerprint, _trustedFp);
    expect(prep.peerName, 'Xiaomi 2410DPN6CC LXR');
    expect(prep.viaIp, _rememberedIp);
    // A pinned address must not be reported as a problem — it is the intended
    // route for an isolated network.
    expect(prep.viaError, isNull);

    home.daemon.dispose();
  });

  testWidgets(
      'an address that answers as a DIFFERENT device is not treated as this '
      'device (and offers no Send button)',
      (tester) async {
    // The address answers, but as the ThinkPad — a real capture whose
    // fingerprint (89507b08…) is not the trusted row's. This is the guard:
    // the address was probably reassigned, and calling it "Reachable" would
    // offer to send files to whoever now holds it.
    final home = await bootHome(
      peers: const [],
      onResolve: (id, _) =>
          okResponse(id, 'resolved_address', resolveUntrustedPayload()),
    );
    addTearDown(home.daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: home.daemon.container,
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pumpAndSettle();

    await refreshHome(tester);
    expect(home.resolveCalls, [_rememberedIp]);

    final tile = knownTile('Xiaomi 2410DPN6CC LXR');
    // Same copy as "nobody answered": the row must not claim this device is at
    // that address.
    expect(find.textContaining('No answer at $_rememberedIp'), findsOneWidget);
    expect(find.textContaining('Reachable'), findsNothing);
    // The address is still shown — the user needs to see which one failed.
    expect(
        find.descendant(of: tile, matching: find.text(_rememberedIp)),
        findsOneWidget);
    // And no Send button: sending here could deliver to the ThinkPad.
    expect(
        find.descendant(of: tile, matching: find.byIcon(Icons.send)),
        findsNothing);

    home.daemon.dispose();
  });

  testWidgets('an address where nobody answers shows no answer and keeps the '
      'address visible', (tester) async {
    final home = await bootHome(
      peers: const [],
      onResolve: (id, _) => okResponse(id, 'resolved_address', {
        'found': false,
        'device_fingerprint': null,
        'device_name': null,
        'trusted': false,
        'quic_port': 47808,
        'tcp_port': 47808,
      }),
    );
    addTearDown(home.daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: home.daemon.container,
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pumpAndSettle();

    await refreshHome(tester);

    final tile = knownTile('Xiaomi 2410DPN6CC LXR');
    expect(find.textContaining('No answer at $_rememberedIp'), findsOneWidget);
    expect(
        find.descendant(of: tile, matching: find.text(_rememberedIp)),
        findsOneWidget,
        reason: 'a failed probe must still say which address was tried');
    expect(
        find.descendant(of: tile, matching: find.byIcon(Icons.send)),
        findsNothing);

    home.daemon.dispose();
  });

  testWidgets('a device that is broadcasting is never probed',
      (tester) async {
    // Discovery already proved this device is on the air; probing its address
    // would be a wasted round trip (and the address may well be stale).
    final home = await bootHome(
      peers: _broadcasting(_trustedFp, 'Xiaomi 2410DPN6CC LXR'),
      onResolve: (id, _) => okResponse(id, 'resolved_address', resolveTrustedPayload()),
    );
    addTearDown(home.daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: home.daemon.container,
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pumpAndSettle();

    await refreshHome(tester);

    expect(home.resolveCalls, isEmpty,
        reason: 'a broadcasting device must not be probed');

    // It is Online, and still sendable — via discovery, not via an address.
    expect(find.textContaining('Online'), findsOneWidget);
    expect(
        find.descendant(
            of: knownTile('Xiaomi 2410DPN6CC LXR'),
            matching: find.byIcon(Icons.send)),
        findsOneWidget);

    home.daemon.dispose();
  });

  testWidgets('a probe that never answers still finishes the refresh and shows '
      'a bounded result', (tester) async {
    // The daemon accepts the request and never replies. The refresh must not
    // hang on it: it gives up at the probe bound and the row settles on a real
    // verdict.
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_peers': (id, _) => okResponse(id, 'peers', const []),
      'list_trusted': (id, _) => listTrustedResponse(id, [
        trustedPeer(_trustedFp,
            name: 'Xiaomi 2410DPN6CC LXR',
            addresses: [trustedPeerAddress(_rememberedIp, 47808, 47808, 3000)]),
      ]),
      'resolve_address': (id, params) =>
          // A hung daemon: no response frame at all for this request id.
          okResponse('some-other-id', 'resolved_address', resolveTrustedPayload()),
    }));
    addTearDown(daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pumpAndSettle();

    // Tap refresh and let the probe bound elapse. If the refresh were
    // unbounded, pumpAndSettle below would never return / the pending-timer
    // check would fail.
    await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
    await tester.pump();
    await tester.pump(kReachabilityProbeTimeout + const Duration(seconds: 1));
    await tester.pumpAndSettle();

    final tile = knownTile('Xiaomi 2410DPN6CC LXR');
    // The row left the "checking" state and reports a real result.
    expect(find.textContaining('Checking'), findsNothing);
    expect(find.textContaining('No answer at $_rememberedIp'), findsOneWidget);
    expect(
        find.descendant(of: tile, matching: find.text(_rememberedIp)),
        findsOneWidget);
    expect(
        find.descendant(of: tile, matching: find.byIcon(Icons.send)),
        findsNothing);

    // The refresh completed: the refresh indicator is gone (no frame left
    // mid-spin) and a further refresh is possible.
    expect(find.byType(RefreshIndicator), findsOneWidget);

    daemon.dispose();
  });
}
