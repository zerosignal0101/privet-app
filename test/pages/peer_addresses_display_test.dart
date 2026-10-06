// A trusted device's remembered addresses are shown in the two places the user
// looks when a send by IP is needed: the recipient picker (where they choose
// the device) and Settings → Trusted Devices (where they check what was used
// before).
//
// `addresses` is additive: a daemon predating it omits the key, and those
// device rows must render exactly as before — no address, no crash.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/settings_page.dart';
import 'package:privet_app/widgets/peer_picker_sheet.dart';

import '../support/test_daemon.dart';

const _identity = {
  'device_fingerprint': 'me',
  'device_name': 'mydev',
};
const _runtimeConfig = {
  'accept_all_trusted': false,
  'collision_policy': 'rename',
  'save_dir': r'C:\received',
};

void main() {
  testWidgets('picker shows the newest remembered address for a known device',
      (tester) async {
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_trusted': (id, _) => listTrustedResponse(id, [
            trustedPeer('trusted-fp',
                name: 'friend',
                addresses: [
                  trustedPeerAddress('10.29.210.120', 47808, 47808, 3000),
                  trustedPeerAddress('192.168.1.7', 47808, 47810, 2000),
                ]),
          ]),
    }));
    addTearDown(daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: Scaffold(body: PeerPickerSheet(onSelected: (fp, {name}) {})),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('friend'), findsOneWidget);
    // The newest remembered address is what the user needs to reuse, so it is
    // rendered with its port (the display form).
    expect(find.textContaining('10.29.210.120:47808'), findsOneWidget);
    // Only the newest is shown inline; the rest are behind the send page.
    expect(find.textContaining('192.168.1.7'), findsNothing);
  });

  testWidgets('a daemon without remembered addresses renders the row unchanged',
      (tester) async {
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_trusted': (id, _) =>
          listTrustedResponse(id, [trustedPeer('trusted-fp', name: 'friend')]),
    }));
    addTearDown(daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: Scaffold(body: PeerPickerSheet(onSelected: (fp, {name}) {})),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('friend'), findsOneWidget);
    expect(find.textContaining('Offline'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings lists the remembered address under the device name',
      (tester) async {
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'get_identity': (id, _) => okResponse(id, 'identity', _identity),
      'get_runtime_config': (id, _) =>
          okResponse(id, 'runtime_config', _runtimeConfig),
      'list_trusted': (id, _) => listTrustedResponse(id, [
            trustedPeer('trusted-fp', name: 'friend', addresses: [
              trustedPeerAddress('10.29.210.120', 47808, 47808, 3000),
            ]),
          ]),
    }));
    addTearDown(daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: const MaterialApp(home: SettingsPage()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Trusted Devices'), findsOneWidget);
    expect(find.text('friend'), findsOneWidget);
    expect(find.textContaining('10.29.210.120:47808'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
