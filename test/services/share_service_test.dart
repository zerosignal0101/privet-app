import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/providers/pending_share.dart';
import 'package:privet_app/services/share_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shareChannel = MethodChannel('privet/share');

  test('start pulls getPendingShare and emits parsed data', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      expect(call.method, 'getPendingShare');
      return {'paths': ['/tmp/a', '/tmp/b']};
    });

    final service = ShareService();
    final received = <PendingShareData>[];
    service.shares.listen(received.add);
    await service.start();
    await pumpEventQueue(); // broadcast stream delivers on a later turn

    expect(received, hasLength(1));
    expect(received[0].paths, ['/tmp/a', '/tmp/b']);
    expect(received[0].text, isNull);
  });

  test('start ignores empty pending share', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(shareChannel, (call) async => null);

    final service = ShareService();
    final received = <PendingShareData>[];
    service.shares.listen(received.add);
    await service.start();

    expect(received, isEmpty);
  });

  test('fromArgs parses paths, text, and rejects non-maps', () {
    final data = PendingShareData.fromArgs({'paths': ['/x'], 'text': 'hi'});
    expect(data.paths, ['/x']);
    expect(data.text, 'hi');
    expect(data.isEmpty, isFalse);

    expect(PendingShareData.fromArgs(null).isEmpty, isTrue);
    expect(PendingShareData.fromArgs({'paths': []}).isEmpty, isTrue);
    expect(PendingShareData.fromArgs({'text': '   '}).isEmpty, isTrue);
  });
}
