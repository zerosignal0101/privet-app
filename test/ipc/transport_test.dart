import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/protocol.dart';
import 'package:privet_app/services/ipc/transport.dart';

void main() {
  test('MemoryTransport connects and echoes scripted replies', () async {
    final transport = MemoryTransport((requests) {
      return requests.map((r) {
        return {
          'type': 'response',
          'request_id': r['request_id'],
          'payload': {'kind': 'pong', 'data': {'protocol_version': 1}},
        };
      }).toList();
    });

    final conn = await transport.connect();
    final buffer = BytesBuilder(copy: false);
    final reply = <String>[];
    final sub = conn.incoming.listen((bytes) {
      buffer.add(bytes);
      while (true) {
        final text = IpcFrameCodec.decode(buffer);
        if (text == null) break;
        reply.add(text);
      }
    });

    conn.out.add(IpcFrameCodec.encode(jsonEncode({
      'protocol_version': 1,
      'request_id': 'r1',
      'request': {'method': 'ping'},
    })));

    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    expect(reply, hasLength(1));
    final decoded = jsonDecode(reply.single) as Map<String, dynamic>;
    expect(decoded['type'], 'response');
    expect(decoded['request_id'], 'r1');
  });

  test('MemoryTransport inject pushes a raw server frame', () async {
    final transport = MemoryTransport((requests) => const []);
    final conn = await transport.connect();
    final buffer = BytesBuilder(copy: false);
    final reply = <String>[];
    final sub = conn.incoming.listen((bytes) {
      buffer.add(bytes);
      while (true) {
        final text = IpcFrameCodec.decode(buffer);
        if (text == null) break;
        reply.add(text);
      }
    });

    transport.inject({
      'type': 'event',
      'sequence': 1,
      'event': {'name': 'device_lost', 'data': {'device_fingerprint': 'fp'}},
    });

    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    expect(reply, hasLength(1));
    final decoded = jsonDecode(reply.single) as Map<String, dynamic>;
    expect(decoded['type'], 'event');
    expect(decoded['sequence'], 1);
  });
}
