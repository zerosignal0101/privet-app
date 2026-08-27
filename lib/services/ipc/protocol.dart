import 'dart:convert';
import 'dart:typed_data';

class IpcProtocolException implements Exception {
  IpcProtocolException(this.message);
  final String message;
  @override
  String toString() => 'IpcProtocolException: $message';
}

/// Framing per spec 09 §3: a four-byte unsigned big-endian JSON byte length
/// followed by exactly that many UTF-8 JSON bytes, max 1 MiB.
class IpcFrameCodec {
  static const int headerBytes = 4;
  static const int maxMessageBytes = 1024 * 1024;

  static Uint8List encode(String jsonText) {
    final bytes = utf8.encode(jsonText);
    if (bytes.length > maxMessageBytes) {
      throw IpcProtocolException('message exceeds $maxMessageBytes bytes');
    }
    final out = BytesBuilder(copy: false);
    final header = Uint8List(headerBytes);
    ByteData.sublistView(header).setUint32(0, bytes.length, Endian.big);
    out.add(header);
    out.add(bytes);
    return out.toBytes();
  }

  /// Decodes one message from [buffer]; returns `null` when more bytes are
  /// needed. Consumes the message (and its 4-byte header) on success.
  static String? decode(BytesBuilder buffer) {
    final bytes = buffer.toBytes();
    if (bytes.length < headerBytes) return null;
    final length = ByteData.sublistView(bytes).getUint32(0, Endian.big);
    if (length > maxMessageBytes) {
      throw IpcProtocolException('frame exceeds $maxMessageBytes bytes');
    }
    if (bytes.length < headerBytes + length) return null;
    final payload = bytes.sublist(headerBytes, headerBytes + length);
    final rest = bytes.sublist(headerBytes + length);
    buffer.clear();
    buffer.add(rest);
    return utf8.decode(payload);
  }
}

/// Reassembles framed messages from a byte stream. Yields one decoded JSON
/// text per complete frame. Throws [IpcProtocolException] on oversized frames.
Stream<String> framesFrom(Stream<List<int>> source) async* {
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in source) {
    buffer.add(chunk);
    while (true) {
      final message = IpcFrameCodec.decode(buffer);
      if (message == null) break;
      yield message;
    }
  }
}

const int ipcProtocolVersion = 1;

/// Validates the envelope's protocol version and returns the parsed object.
Map<String, dynamic> decodeEnvelope(String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map<String, dynamic>) {
    throw IpcProtocolException('envelope is not a JSON object');
  }
  if (decoded['protocol_version'] != ipcProtocolVersion) {
    throw IpcProtocolException(
        'incompatible protocol version: ${decoded['protocol_version']}');
  }
  return decoded;
}

/// Builds a client envelope `{protocol_version, request_id, request{method,
/// params}}` as JSON bytes, ready to be framed by the transport. (Framing is
/// a codec concern: callers that write to a wire apply [IpcFrameCodec.encode]
/// themselves.)
Uint8List encodeRequest(
  String requestId,
  String method,
  Map<String, dynamic>? params,
) {
  final request = <String, dynamic>{
    'method': method,
    if (params != null && params.isNotEmpty) 'params': params,
  };
  return utf8.encode(jsonEncode({
    'protocol_version': ipcProtocolVersion,
    'request_id': requestId,
    'request': request,
  }));
}
