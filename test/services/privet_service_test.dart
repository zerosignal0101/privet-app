import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/client.dart';
import 'package:privet_app/services/privet_service.dart';

class _NoTransport implements Transport {
  @override
  Future<TransportConnection> connect() async => throw UnimplementedError();
}

class _StubClient extends PrivetIpcClient {
  _StubClient() : super(_NoTransport());
  int sendCalls = 0;
  String? lastFingerprint;
  @override
  Future<String> send(List<String> paths, String fingerprint, {String? asName}) async {
    sendCalls++;
    lastFingerprint = fingerprint;
    return 't-1';
  }
}

void main() {
  test('send delegates to the client', () async {
    final stub = _StubClient();
    final service = PrivetService(stub);
    final id = await service.send(['a.txt'], 'fp');
    expect(id, 't-1');
    expect(stub.sendCalls, 1);
    expect(stub.lastFingerprint, 'fp');
  });
}
