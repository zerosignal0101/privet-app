// The Send Files page must judge a device the same way the Home page does.
//
// The bug this pins: the home page asks "is this device there?" (a beacon, or
// an address probe that answered as the right fingerprint), while the send page
// asked only "is it broadcasting right now?" (`p.isOnline`). A device that was
// reachable at a remembered address but not advertising — the Z690 case — was
// therefore "Reachable at 10.29.218.79" on the row the user had just tapped and
// "offline" on the page it opened, and the send was gated on the wrong one of
// those two answers.
//
// So every test here asserts the composed verdict, and the important ones assert
// on what the daemon actually receives rather than on rendered text alone: the
// failure mode was a wrong verdict *crossing into the send*, so a green widget
// tree with a suppressed `via` would be the same bug wearing a different hat.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/send_preparation_page.dart';
import 'package:privet_app/providers/peers.dart';
import 'package:privet_app/providers/send_preparation.dart';

import '../support/resolve_fixtures.dart';
import '../support/test_daemon.dart';

/// The fingerprint the real `resolve_address` capture in resolve_fixtures.dart
/// answers with. Using the fixture's own fingerprint is what makes "the same
/// identity answered" a fact about the capture rather than an arbitrary string.
const _trustedFp =
    '828312c176632a80f48fa41e57e48655af6d97a838e86b9a6ffd9eb7f374feac';

const _name = 'Z690';
const _rememberedIp = '10.29.218.79';

const _identity = {
  'device_fingerprint': 'me',
  'device_name': 'mydev',
};
const _runtimeConfig = {
  'accept_all_trusted': false,
  'collision_policy': 'rename',
  'save_dir': r'C:\received',
};

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

/// A `resolve_address` answer for "nobody is there".
Map<String, dynamic> _noAnswer(String id) => okResponse(id, 'resolved_address', {
      'found': false,
      'device_fingerprint': null,
      'device_name': null,
      'trusted': false,
      'quic_port': 47808,
      'tcp_port': 47808,
    });

/// Boots the Send Files page over a daemon holding [_trustedFp].
///
/// [onResolve] answers the page's single reachability probe; every call is
/// recorded in [resolveCalls] so a test can assert a probe did — or did not —
/// happen, and [sends] collects the params the daemon received for `send`, which
/// is what carries the `via` decision across into the transfer.
///
/// [sends] is a list rather than a single nullable field on purpose: the
/// environment is handed back as an immutable record, so a captured variable
/// would be snapshotted at return time and always read as "nothing was sent".
Future<({TestDaemon daemon, List<String> resolveCalls, List<Map<String, dynamic>> sends})>
    bootSendPage({
  required Map<String, dynamic> Function(String id, Map<String, dynamic> params)
      onResolve,
  List<Map<String, dynamic>> peers = const [],
  List<Map<String, dynamic>>? trusted,
}) async {
  final resolveCalls = <String>[];
  final sends = <Map<String, dynamic>>[];
  final trustedRecord = trusted ??
      [
        trustedPeer(_trustedFp,
            name: _name,
            addresses: [trustedPeerAddress(_rememberedIp, 47808, 47808, 3000)]),
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
    'send': (id, params) {
      sends.add(Map<String, dynamic>.from(params));
      return okResponse(id, 'transfer_queued', {'transfer_id': 't-r16'});
    },
  }));
  return (daemon: daemon, resolveCalls: resolveCalls, sends: sends);
}

/// Pumps enough frames for the FutureProviders, the page's one-shot probe, and
/// the daemon round trip to land, without waiting on an unbounded settle.
Future<void> _settleFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

String _makeFile(String dirName) {
  final dir = Directory('${Directory.systemTemp.path}/$dirName')
    ..createSync(recursive: true);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final file = File('${dir.path}/a.txt')..writeAsStringSync('hello');
  return file.path;
}

Future<void> _pumpSendPage(
  WidgetTester tester,
  TestDaemon daemon,
  String file,
) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: daemon.container,
    child: MaterialApp(
      home: SendPreparationPage(
        initialEntries: [
          SendFileEntry(path: file, relativePath: 'a.txt', size: 5),
        ],
        initialPeerFingerprint: _trustedFp,
        initialPeerName: _name,
      ),
    ),
  ));
  await _settleFrames(tester);
}

void main() {
  testWidgets('a discovered device is not offline, is not probed, and is sent '
      'to without an address', (tester) async {
    // The normal case. Discovery is a complete answer, so the page must not
    // spend a probe on it, and must hand the engine nothing to dial: the send
    // goes out as a bare device request.
    final env = await bootSendPage(
      peers: _broadcasting(_trustedFp, _name),
      onResolve: (id, _) =>
          okResponse(id, 'resolved_address', resolveTrustedPayload()),
      // No remembered address: there is nothing to prefill and nothing to probe,
      // which is exactly the case where `via` must stay absent.
      trusted: [trustedPeer(_trustedFp, name: _name)],
    );
    addTearDown(env.daemon.dispose);

    final file = _makeFile('privet-r16-online');
    await _pumpSendPage(tester, env.daemon, file);

    expect(env.resolveCalls, isEmpty,
        reason: 'a broadcasting device must not be probed');

    // Not called offline, and not dressed up as a problem either.
    expect(find.textContaining('offline'), findsNothing);
    expect(find.byIcon(Icons.cloud_off), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);

    expect(env.sends, hasLength(1),
        reason: 'a discovered device must be sendable');
    expect(env.sends.single['device_fingerprint'], _trustedFp);
    expect(env.sends.single['via'], isNull,
        reason: 'discovery needs no address, so none may be pinned');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a device reachable at a remembered address is NOT offline, and '
      'the send carries that address as via', (tester) async {
    // The reported bug, exactly. The address answers as the same device the
    // page is about (the real Xiaomi capture), and the device is not
    // broadcasting — so discovery says nothing at all and only the probe knows.
    final env = await bootSendPage(
      onResolve: (id, _) =>
          okResponse(id, 'resolved_address', resolveTrustedPayload()),
    );
    addTearDown(env.daemon.dispose);

    final file = _makeFile('privet-r16-reachable');
    await _pumpSendPage(tester, env.daemon, file);

    // Entering the page asked the one question it needed to ask, at the
    // remembered address.
    expect(env.resolveCalls, [_rememberedIp]);

    // The verdict matches the home page's, and the word "offline" is gone —
    // this is the assertion that failed before the fix.
    expect(find.textContaining('offline'), findsNothing);
    expect(find.textContaining('Reachable at $_rememberedIp'), findsOneWidget);
    // The verdict names the device, never the raw fingerprint.
    expect(find.textContaining(_trustedFp), findsNothing);
    expect(find.byIcon(Icons.cloud_off), findsNothing);

    // The address the user can see is the address that is sent: the invariant
    // the address box already holds, now satisfied by the probe's own record.
    final state = env.daemon.container.read(sendPreparationProvider);
    expect(state.viaIp, _rememberedIp);
    expect(state.viaError, isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);

    // Asserted on what the daemon received, not on the label above it: the bug
    // was a wrong verdict crossing into the send.
    expect(env.sends, hasLength(1),
        reason: 'a device proved reachable at an address must be sendable');
    expect(env.sends.single['device_fingerprint'], _trustedFp);
    expect(env.sends.single['via'], _rememberedIp);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a genuinely unreachable device is blocked, and the message says '
      'which address was tried', (tester) async {
    // The probe asked and nothing answered. This — and only this — is offline.
    final env = await bootSendPage(onResolve: (id, _) => _noAnswer(id));
    addTearDown(env.daemon.dispose);

    final file = _makeFile('privet-r16-unreachable');
    await _pumpSendPage(tester, env.daemon, file);

    expect(env.resolveCalls, [_rememberedIp]);

    // Honest about what it knows: an address was tried, and it did not answer.
    expect(find.textContaining('No answer at $_rememberedIp'), findsOneWidget);
    // Twice on purpose: the recipient row is captioned offline and the notice
    // explains it. Both come from the one verdict.
    expect(find.byIcon(Icons.cloud_off), findsWidgets);

    // Clear the box, so there is no route left to override the verdict with.
    await tester.enterText(find.byKey(const Key('via-address-field')), '');
    await _settleFrames(tester);
    expect(env.daemon.container.read(sendPreparationProvider).viaIp, isNull);

    // The gate agrees with the screen: pressing Send must not reach the daemon,
    // which would only spin against a dead address.
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);

    expect(env.sends, isEmpty,
        reason: 'an unreachable device with no route must never reach the daemon');
    expect(find.textContaining('did not answer at $_rememberedIp'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pinned address still overrides an unanswered probe', (tester) async {
    // The escape hatch for beacon-blocked networks, and pre-existing behaviour
    // that this change must not take away: the box arrives pre-filled with the
    // remembered address, the user asked for that route on purpose, so a probe
    // that got no answer must not overrule them. Note the page still *says*
    // the address did not answer — the override is a send decision, not a
    // different verdict.
    final env = await bootSendPage(onResolve: (id, _) => _noAnswer(id));
    addTearDown(env.daemon.dispose);

    final file = _makeFile('privet-r16-override');
    await _pumpSendPage(tester, env.daemon, file);

    expect(find.textContaining('No answer at $_rememberedIp'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);

    expect(env.sends, hasLength(1),
        reason: 'a pinned address is the documented override');
    expect(env.sends.single['device_fingerprint'], _trustedFp);
    expect(env.sends.single['via'], _rememberedIp);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a device with no address and nothing probed is not called '
      'offline, and the send is blocked for the real reason', (tester) async {
    // No remembered address, so there is nothing to dial and no probe is
    // possible. `unknown` is "we have not looked", not "it is gone" — and the
    // wording must not invent a failure that was never observed.
    final env = await bootSendPage(
      onResolve: (id, _) => _noAnswer(id),
      trusted: [trustedPeer(_trustedFp, name: _name)],
    );
    addTearDown(env.daemon.dispose);

    final file = _makeFile('privet-r16-unknown');
    await _pumpSendPage(tester, env.daemon, file);

    expect(env.resolveCalls, isEmpty,
        reason: 'with no remembered address there is nothing to probe');

    expect(find.textContaining('is offline'), findsNothing);
    expect(find.textContaining('has not been heard from'), findsOneWidget);
    expect(find.textContaining('not the same as being offline'), findsOneWidget);

    // Blocked, and for the honest reason: there is no route, not "it is off".
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await _settleFrames(tester);

    expect(env.sends, isEmpty);
    // The gate's message and the notice above it must agree, so this string
    // legitimately appears twice — once grey, once as the error.
    expect(find.textContaining('no address is remembered'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the page probes a remembered address exactly once, and never '
      'polls', (tester) async {
    // A bounded probe is the whole mechanism, so "bounded" and "once" are the
    // load-bearing properties: a timer or a subscription here would keep
    // firing after the page settles, and the pending-timer check at the end of
    // the test is what would catch it.
    final env = await bootSendPage(
      onResolve: (id, _) =>
          okResponse(id, 'resolved_address', resolveTrustedPayload()),
    );
    addTearDown(env.daemon.dispose);

    final file = _makeFile('privet-r16-once');
    await _pumpSendPage(tester, env.daemon, file);

    expect(env.resolveCalls, [_rememberedIp]);

    // Well past the probe bound, and across many more frames: if anything were
    // polling, it would have fired again by now.
    for (var i = 0; i < 10; i++) {
      await tester.pump(kReachabilityProbeTimeout);
    }
    expect(env.resolveCalls, [_rememberedIp],
        reason: 'the probe must be a one-shot, not a poll');

    // No stray timer is left holding the frame open.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('an address that answers as a DIFFERENT device is not treated as '
      'this device', (tester) async {
    // The remembered address has been handed to a different machine (the
    // ThinkPad capture). Treating "something answered" as "my friend is there"
    // would offer to deliver files to a stranger, so this is unreachable —
    // identical to "nobody answered", and the copy must not imply otherwise.
    final env = await bootSendPage(
      onResolve: (id, _) =>
          okResponse(id, 'resolved_address', resolveUntrustedPayload()),
    );
    addTearDown(env.daemon.dispose);

    final file = _makeFile('privet-r16-wrong-device');
    await _pumpSendPage(tester, env.daemon, file);

    expect(find.textContaining('Reachable'), findsNothing);
    expect(find.textContaining('No answer at $_rememberedIp'), findsOneWidget);

    // Note: the address box is still pre-filled with the remembered address, so
    // this is the pinned-address escape hatch the user can override with — the
    // gate allows it on purpose. The verdict itself must not be `reachable`.
    expect(
        env.daemon.container
            .read(peerReachVerdictProvider(_trustedFp))
            .state,
        TrustedReachability.unreachable);
    expect(tester.takeException(), isNull);
  });
}
