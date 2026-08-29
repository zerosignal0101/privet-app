// Regression: renaming the App Device Name in Settings restarts the daemon so
// discovery announces the new name immediately. The rename flow used to crash
// with a "_dependents.isEmpty" framework assertion — the device-name dialog
// disposed its TextEditingController as soon as showDialog's future resolved,
// while the dialog route was still fading out and its TextField still owned the
// controller. That exception corrupted the element teardown into the
// `_dependents.isEmpty` assert. The controller must live until the route
// subtree unmounts (owned by the dialog's State.dispose).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/main.dart';
import 'package:privet_app/state/daemon_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_daemon.dart';

void main() {
  testWidgets('renaming device name survives the daemon restart', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final supervisor = StubSupervisor();
    await tester.pumpWidget(ProviderScope(
      overrides: [daemonSupervisorProvider.overrideWithValue(supervisor)],
      child: const PrivetApp(),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('Privet'), findsOneWidget);

    // Navigate to the Settings tab.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    // Rename the device.
    await tester.tap(find.text('App Device Name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'renamed-device');
    await tester.tap(find.text('Save'));
    // The rename triggers a daemon restart (stop + start), which churns every
    // provider while the Settings page stays mounted.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    // The new name is persisted and shown (settings subtitle).
    expect(find.text('renamed-device'), findsWidgets);
  });
}
