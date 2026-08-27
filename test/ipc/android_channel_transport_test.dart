import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/android_channel_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ipcChannel = MethodChannel('privet/ipc');
  const eventsChannel = EventChannel('privet/ipc/events');

  test('connect opens the socket; outbound bytes reach the write method',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    String? openedPath;
    final writes = <Uint8List>[];
    var closed = 0;
    messenger.setMockMethodCallHandler(ipcChannel, (call) async {
      switch (call.method) {
        case 'open':
          openedPath = (call.arguments as Map)['path'] as String?;
          break;
        case 'write':
          writes.add((call.arguments as Map)['data'] as Uint8List);
          break;
        case 'close':
          closed++;
          break;
      }
      return null;
    });

    const path = '/data/user/0/app.privet.privet_app/files/privet/privet.sock';
    final transport = AndroidChannelTransport(path);
    final conn = await transport.connect();

    expect(openedPath, path);

    conn.out.add(Uint8List.fromList([1, 2, 3]));
    conn.out.add(Uint8List.fromList([4, 5]));
    await pumpEventQueue();
    expect(writes, hasLength(2));
    expect(writes[0], [1, 2, 3]);
    expect(writes[1], [4, 5]);

    await conn.out.close();
    await pumpEventQueue();
    expect(closed, 1);
  });

  test('incoming event chunks are forwarded on the connection stream', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    MockStreamHandlerEventSink? sink;
    messenger.setMockStreamHandler(
      eventsChannel,
      MockStreamHandler.inline(onListen: (arguments, events) {
        sink = events;
      }),
    );
    messenger.setMockMethodCallHandler(ipcChannel, (call) async => null);

    final transport = AndroidChannelTransport('/tmp/privet.sock');
    final conn = await transport.connect();

    final received = <List<int>>[];
    conn.incoming.listen(received.add);

    sink!.success(Uint8List.fromList([0x68, 0x69]));
    await pumpEventQueue();
    expect(received, hasLength(1));
    expect(received[0], [0x68, 0x69]);

    await conn.out.close();
  });
}
