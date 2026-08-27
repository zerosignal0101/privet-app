import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/protocol.dart';

void main() {
  group('IpcFrameCodec', () {
    test('round-trips a message', () {
      const text = '{"a":1}';
      final buffer = BytesBuilder(copy: false)..add(IpcFrameCodec.encode(text));
      expect(IpcFrameCodec.decode(buffer), text);
      expect(buffer.length, 0);
    });

    test('returns null until a full frame is buffered', () {
      final encoded = IpcFrameCodec.encode('{"long":"payload"}');
      final buffer = BytesBuilder(copy: false)..add(encoded.sublist(0, 5));
      expect(IpcFrameCodec.decode(buffer), isNull);
      buffer.add(encoded.sublist(5));
      expect(IpcFrameCodec.decode(buffer), '{"long":"payload"}');
    });

    test('rejects messages larger than the 1 MiB limit', () {
      final big = Uint8List(IpcFrameCodec.maxMessageBytes + 1);
      expect(() => IpcFrameCodec.encode(utf8.decode(big)),
          throwsA(isA<IpcProtocolException>()));
    });

    test('rejects frames whose header declares an oversized length', () {
      final header = Uint8List(8);
      ByteData.sublistView(header)
          .setUint32(0, IpcFrameCodec.maxMessageBytes + 1, Endian.big);
      final buffer = BytesBuilder(copy: false)..add(header);
      expect(() => IpcFrameCodec.decode(buffer),
          throwsA(isA<IpcProtocolException>()));
    });
  });

  group('framesFrom', () {
    test('yields each message in order', () async {
      final source = Stream<List<int>>.fromIterable([
        IpcFrameCodec.encode('"one"'),
        IpcFrameCodec.encode('"two"'),
      ]);
      await expectLater(framesFrom(source), emitsInOrder(['"one"', '"two"']));
    });

    test('yields a message split across chunks', () async {
      final encoded = IpcFrameCodec.encode('"split"');
      final source = Stream<List<int>>.fromIterable([
        encoded.sublist(0, 3),
        encoded.sublist(3),
      ]);
      await expectLater(framesFrom(source), emits('"split"'));
    });

    test('propagates oversized frame errors', () async {
      final header = Uint8List(8);
      ByteData.sublistView(header)
          .setUint32(0, IpcFrameCodec.maxMessageBytes + 1, Endian.big);
      await expectLater(
        framesFrom(Stream.value(header)),
        emitsError(isA<IpcProtocolException>()),
      );
    });
  });

  group('envelope', () {
    test('encodes request with id, method and params', () {
      final bytes = encodeRequest('req-1', 'get_status', null);
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(json['protocol_version'], 1);
      expect(json['request_id'], 'req-1');
      expect(json['request'], {'method': 'get_status'});
    });

    test('decodeEnvelope rejects wrong protocol version', () {
      expect(
        () => decodeEnvelope('{"protocol_version":99,"request_id":"r","request":{}}'),
        throwsA(isA<IpcProtocolException>()),
      );
    });
  });
}
