import 'dart:async';
import 'dart:convert';

import 'protocol.dart';

/// A dumb bidirectional byte channel. Implementations must not do protocol
/// work; they only move bytes.
abstract class Transport {
  Future<TransportConnection> connect();
}

class TransportConnection {
  TransportConnection({required this.incoming, required this.out});
  final Stream<List<int>> incoming;
  final StreamSink<List<int>> out;
}

/// In-memory transport for tests. The [script] receives each request message
/// map (with its `request_id`) and returns the server messages (responses
/// and/or events) to emit, in order. Requests are answered FIFO.
class MemoryTransport implements Transport {
  MemoryTransport(this.script);

  final List<Map<String, dynamic>> Function(List<Map<String, dynamic>> requests) script;

  /// Broadcast so multiple listeners (a test and a client) can coexist; events
  /// are only delivered to listeners subscribed at emission time.
  final _incoming = StreamController<List<int>>.broadcast();
  final _requests = <Map<String, dynamic>>[];

  @override
  Future<TransportConnection> connect() async {
    final out = StreamController<List<int>>();
    // Mirrors the real transports: the client writes framed bytes, so decode
    // frames before handing each request JSON to the script.
    framesFrom(out.stream).listen((jsonText) => submit(jsonText));
    return TransportConnection(incoming: _incoming.stream, out: out.sink);
  }

  /// Test helper: submit a request frame and emit the scripted replies.
  void submit(String frameJson) {
    final request = jsonDecode(frameJson) as Map<String, dynamic>;
    _requests.add(request);
    final replies = script([request]);
    for (final reply in replies) {
      _incoming.add(IpcFrameCodec.encode(jsonEncode(reply)));
    }
  }

  /// Push a raw server frame (map) onto the incoming byte stream, bypassing
  /// the request/response script. Used to simulate live events.
  void inject(Map<String, dynamic> serverMessage) =>
      _incoming.add(IpcFrameCodec.encode(jsonEncode(serverMessage)));
}
