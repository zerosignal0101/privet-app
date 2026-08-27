import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/unix_socket_transport.dart';

void main() {
  test('connects and echoes bytes over a unix socket', () async {
    if (Platform.isWindows) return; // POSIX-only
    final dir = await Directory.systemTemp.createTemp('privet-sock');
    final path = '${dir.path}/test.sock';
    final address = InternetAddress(path, type: InternetAddressType.unix);
    final server = await ServerSocket.bind(address, 0);
    final serverSub = server.listen((socket) {
      // Echo the client's bytes back.
      socket.listen((data) => socket.add(data), onError: (_) {});
    });
    addTearDown(() async {
      await serverSub.cancel();
      await server.close();
      await dir.delete(recursive: true);
    });

    final transport = UnixSocketTransport(path);
    final conn = await transport.connect();
    final reply = <int>[];
    final sub = conn.incoming.listen(reply.addAll);
    conn.out.add(utf8.encode('hello'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();
    expect(utf8.decode(reply), 'hello');
  });
}
