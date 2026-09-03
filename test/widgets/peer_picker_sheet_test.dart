// The recipient picker must offer BOTH the full known/trusted device list
// (selectable even when the device is offline or hasn't broadcast) and
// discovered nearby peers. A trusted device that is also currently discovered
// appears once, under Known Devices.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/widgets/peer_picker_sheet.dart';

import '../support/test_daemon.dart';

void main() {
  testWidgets('picker marks offline devices, dedupes trusted, selects online',
      (tester) async {
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
          ]),
    }));
    addTearDown(daemon.dispose);

    String? selectedFp;
    String? selectedName;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: MaterialApp(
        home: Scaffold(
          body: PeerPickerSheet(
            onSelected: (fp, {name}) {
              selectedFp = fp;
              selectedName = name;
            },
          ),
        ),
      ),
    ));
    await tester.pump();

    // The trusted list loads on build.
    expect(find.text('friend'), findsOneWidget);
    expect(find.text('Known Devices'), findsOneWidget);

    // The known device has NOT broadcast yet -> clearly marked Offline and not
    // selectable, so a send to it is impossible.
    expect(find.textContaining('Offline'), findsOneWidget);
    final offlineTile = find.widgetWithText(ListTile, 'friend');
    expect(tester.widget<ListTile>(offlineTile).enabled, isFalse,
        reason: 'an offline device must not be selectable');

    // A discovered peer that is NOT trusted lands under Nearby Devices; a
    // discovered peer that IS trusted is deduped into Known Devices only.
    daemon.transport.inject(_event(1, 'device_discovered',
        {'device_fingerprint': 'trusted-fp', 'device_name': 'friend'}));
    daemon.transport.inject(_event(2, 'device_discovered',
        {'device_fingerprint': 'nearby-fp', 'device_name': 'laptop'}));
    await tester.pump();

    expect(find.text('Nearby Devices'), findsOneWidget);
    expect(find.text('laptop'), findsOneWidget);
    expect(find.text('Offline'), findsNothing);
    // 'friend' appears exactly once (Known Devices), not again under Nearby.
    expect(find.text('friend'), findsOneWidget);

    // Tapping the now-online known device selects it.
    await tester.tap(find.text('friend'));
    await tester.pump();
    expect(selectedFp, 'trusted-fp');
    expect(selectedName, 'friend');
  });
}

Map<String, dynamic> _event(
        int seq, String name, Map<String, dynamic> data) =>
    {'type': 'event', 'sequence': seq, 'event': {'name': name, 'data': data}};
