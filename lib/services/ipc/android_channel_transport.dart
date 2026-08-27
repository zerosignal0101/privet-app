import 'dart:async';

import 'package:flutter/services.dart';

import 'transport.dart';

/// Android transport that bridges Dart bytes to the on-device privetd unix
/// socket through the `privet/ipc` MethodChannel/EventChannel pair. The Kotlin
/// side is a dumb byte pipe; all framing stays here in Dart (IpcFrameCodec).
class AndroidChannelTransport implements Transport {
  AndroidChannelTransport(this.socketPath);
  final String socketPath;

  static const MethodChannel _method = MethodChannel('privet/ipc');
  static const EventChannel _events = EventChannel('privet/ipc/events');

  @override
  Future<TransportConnection> connect() async {
    await _method.invokeMethod<void>('open', {'path': socketPath});

    final incoming = StreamController<List<int>>();
    final out = StreamController<List<int>>();

    _events.receiveBroadcastStream().listen(
          (chunk) => incoming.add((chunk as Uint8List)),
          onError: (Object e) => incoming.addError(e),
          onDone: () async {
            await incoming.close();
            await out.close();
          },
        );

    out.stream.listen(
      // MethodChannel encodes Uint8List as a ByteArray; a plain List<int> would
      // arrive as a list of integers, so normalize defensively.
      (bytes) => _method
          .invokeMethod<void>('write', {'data': Uint8List.fromList(bytes)}),
      onError: (_) {},
      onDone: () => _method.invokeMethod<void>('close'),
    );

    return TransportConnection(incoming: incoming.stream, out: out.sink);
  }
}
