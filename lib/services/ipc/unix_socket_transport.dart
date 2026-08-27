import 'dart:async';
import 'dart:io';

import 'transport.dart';

class UnixSocketConnectException implements Exception {
  UnixSocketConnectException(this.socketPath, this.cause);
  final String socketPath;
  final Object cause;
  @override
  String toString() => 'UnixSocketConnectException($socketPath): $cause';
}

/// Unix-domain-socket client (Linux/macOS) using dart:io.
///
/// Dart 3.12 removed the dedicated `UnixDomainSocket` class; unix sockets are
/// now created through [InternetAddress] with [InternetAddressType.unix].
class UnixSocketTransport implements Transport {
  UnixSocketTransport(this.socketPath);
  final String socketPath;

  @override
  Future<TransportConnection> connect() async {
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
    } catch (e) {
      throw UnixSocketConnectException(socketPath, e);
    }
    final incoming = StreamController<List<int>>();
    final out = StreamController<List<int>>();
    socket.listen(
      (bytes) => incoming.add(bytes),
      onError: (Object e, StackTrace st) => incoming.addError(e, st),
      onDone: () async {
        await incoming.close();
        await out.close();
      },
      cancelOnError: true,
    );
    out.stream.listen(
      (bytes) => socket.add(bytes),
      onError: (_) {},
      onDone: () => socket.destroy(),
    );
    return TransportConnection(incoming: incoming.stream, out: out.sink);
  }
}
