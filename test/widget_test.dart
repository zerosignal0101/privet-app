import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/main.dart';
import 'package:privet_app/state/daemon_state.dart';

import 'support/test_daemon.dart';

void main() {
  testWidgets('app boots to the shell with a running daemon', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        daemonSupervisorProvider.overrideWithValue(StubSupervisor()),
      ],
      child: const PrivetApp(),
    ));
    // Let the post-frame start() complete: starting -> running.
    await tester.pump();
    await tester.pump();
    expect(find.text('Privet'), findsOneWidget);
  });
}
