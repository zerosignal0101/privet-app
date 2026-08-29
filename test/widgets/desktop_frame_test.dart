// Desktop keeps the phone-width layout: the app is a mobile design (bottom nav
// + dense ListTiles), so the native window is resized to a phone-like ratio and
// the content is capped at 480px if the window is stretched wider. The whole
// window is painted with the app's surface color so a wider-than-480 window
// shows the app background beside the column, never black. On phones the app
// fills the screen.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/main.dart';
import 'package:privet_app/state/daemon_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_daemon.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      overrides: [daemonSupervisorProvider.overrideWithValue(StubSupervisor())],
      child: const PrivetApp(),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('Privet'), findsOneWidget);
  }

  testWidgets('desktop caps the app at 480px and paints the app background',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpApp(tester);
      final navBar = tester.getSize(find.byType(NavigationBar));
      expect(navBar.width, 480);

      // The area beside the column is the app's scaffold background, so a wide
      // (or maximized) window shows the theme surface instead of black borders.
      final surface =
          Theme.of(tester.element(find.byType(NavigationBar)))
              .scaffoldBackgroundColor;
      final frame = tester.widget<ColoredBox>(
          find.byKey(const ValueKey('phone-frame')));
      expect(frame.color, surface);
      // And the surface color is not black.
      expect(surface, isNot(Colors.black));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('android fills the whole screen', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpApp(tester);
      final navBar = tester.getSize(find.byType(NavigationBar));
      expect(navBar.width, 800); // the default test surface width
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
