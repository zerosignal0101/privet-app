// The home page must show this machine's own dialable addresses so a user can
// pair manually when automatic discovery cannot get through (campus AP client
// isolation). Covered here: every address renders (multi-NIC hosts have more
// than one), a daemon without the field degrades to a notice instead of an
// empty block, and the copy button puts exactly the displayed string on the
// clipboard so it can be pasted into the other device's pair-by-address box.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/home_page.dart';

import '../support/test_daemon.dart';

/// Boots a home page against a fake daemon whose `get_status` carries
/// [localAddrs] (null omits the field entirely, as an older daemon would).
Future<TestDaemon> _bootHome(List<Map<String, dynamic>>? localAddrs) async {
  return bootTestDaemon(scriptFromHandlers({
    'get_status': (id, _) => statusResponseWithAddrs(id, localAddrs),
    'get_identity': (id, _) => okResponse(id, 'identity', {
          'device_fingerprint': 'me',
          'device_name': 'mydev',
        }),
    'get_runtime_config': (id, _) => okResponse(id, 'runtime_config', {
          'accept_all_trusted': false,
          'collision_policy': 'rename',
          'save_dir': r'C:\received',
        }),
    'list_peers': (id, _) => okResponse(id, 'peers', <dynamic>[]),
    'list_trusted': (id, _) => okResponse(id, 'trusted', <dynamic>[]),
  }));
}

Map<String, dynamic> _addr(String ip, int quic, int tcp) =>
    {'ip': ip, 'quic_port': quic, 'tcp_port': tcp};

Future<void> _pumpHome(WidgetTester tester, TestDaemon daemon) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: daemon.container,
    child: const MaterialApp(home: HomePage()),
  ));
  await tester.pumpAndSettle();
  // UncontrolledProviderScope does not own the container; dispose it before the
  // test ends so activeTransfersProvider's periodic timer is cancelled.
  daemon.dispose();
}

void main() {
  testWidgets('renders every local address, with ports and a copy button each',
      (tester) async {
    final daemon = await _bootHome([
      _addr('10.29.210.120', 47808, 47808),
      _addr('192.168.1.7', 47808, 47810),
      _addr('fe80::1c2b:3d4e', 47808, 47808),
    ]);
    await _pumpHome(tester, daemon);

    expect(find.text('This Machine'), findsOneWidget);

    // All three render — listing only the first would defeat the purpose on a
    // host with both wired and wireless NICs.
    expect(find.text('10.29.210.120:47808'), findsOneWidget);
    expect(find.text('192.168.1.7:47808'), findsOneWidget);
    // IPv6 is bracketed so the port is not ambiguous.
    expect(find.text('[fe80::1c2b:3d4e]:47808'), findsOneWidget);

    // QUIC and TCP ports are both surfaced (they may differ).
    expect(find.text('QUIC 47808 · TCP 47808'), findsNWidgets(2));
    expect(find.text('QUIC 47808 · TCP 47810'), findsOneWidget);

    // One copy button per address.
    expect(find.byIcon(Icons.copy), findsNWidgets(3));
  });

  testWidgets('missing local_addrs field shows a notice, not an empty block',
      (tester) async {
    // A daemon predating the field: the parse must not throw and the home page
    // must still build.
    final daemon = await _bootHome(null);
    await _pumpHome(tester, daemon);

    expect(find.text('This Machine'), findsOneWidget);
    expect(find.textContaining('No local address available'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty local_addrs list shows the same notice', (tester) async {
    final daemon = await _bootHome([]);
    await _pumpHome(tester, daemon);

    expect(find.textContaining('No local address available'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy puts the displayed dial string on the clipboard',
      (tester) async {
    final daemon = await _bootHome([
      _addr('10.29.210.120', 47808, 47808),
      _addr('fe80::1c2b:3d4e', 47808, 47808),
    ]);
    await _pumpHome(tester, daemon);

    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    // Copy the IPv6 entry: the text on the clipboard must equal the text shown.
    final ipv6Copy = find.ancestor(
      of: find.text('[fe80::1c2b:3d4e]:47808'),
      matching: find.byType(ListTile),
    );
    await tester.tap(find.descendant(
        of: ipv6Copy, matching: find.byIcon(Icons.copy)));
    await tester.pumpAndSettle();
    expect(clipboard, '[fe80::1c2b:3d4e]:47808');

    // And the IPv4 one.
    final ipv4Copy = find.ancestor(
      of: find.text('10.29.210.120:47808'),
      matching: find.byType(ListTile),
    );
    await tester.tap(find.descendant(
        of: ipv4Copy, matching: find.byIcon(Icons.copy)));
    await tester.pumpAndSettle();
    expect(clipboard, '10.29.210.120:47808');
  });
}
