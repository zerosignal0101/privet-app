import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/android/daemon_bundle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const serviceChannel = MethodChannel('privet/daemon_service');

  test('startForegroundService invokes the start method', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var invoked = false;
    messenger.setMockMethodCallHandler(serviceChannel, (call) async {
      expect(call.method, 'start');
      invoked = true;
      return null;
    });

    await startForegroundService();

    expect(invoked, isTrue);
  });

  test('startForegroundService is a no-op when the channel is absent', () async {
    // No mock registered -> invokeMethod throws, which must be swallowed.
    await startForegroundService();
  });
}
