import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/client.dart';
import 'package:privet_app/services/ipc/requests.dart';
import 'package:privet_app/services/privet_service.dart';

class _NoTransport implements Transport {
  @override
  Future<TransportConnection> connect() async => throw UnimplementedError();
}

class _StubClient extends PrivetIpcClient {
  _StubClient() : super(_NoTransport());
  int sendCalls = 0;
  String? lastFingerprint;
  String? lastVia;
  @override
  Future<String> send(List<String> paths, String fingerprint,
      {String? asName, String? via}) async {
    sendCalls++;
    lastFingerprint = fingerprint;
    lastVia = via;
    return 't-1';
  }
}

void main() {
  test('an explicit via reaches the wire as a bare IP in the send request',
      () async {
    // End-to-end over the request builder: the field name, its omission when
    // unset, and the absence of a port are all part of the engine contract.
    final withVia = reqSend(['a.txt'], 'fp', via: '10.29.210.120')['request']
        as Map<String, dynamic>;
    final params = withVia['params'] as Map<String, dynamic>;
    expect(params['via'], '10.29.210.120');

    final withoutVia = reqSend(['a.txt'], 'fp')['request']
        as Map<String, dynamic>;
    final bare = withoutVia['params'] as Map<String, dynamic>;
    expect(bare.containsKey('via'), isFalse);
  });

  test('send delegates to the client', () async {
    final stub = _StubClient();
    final service = PrivetService(stub);
    final id = await service.send(['a.txt'], 'fp');
    expect(id, 't-1');
    expect(stub.sendCalls, 1);
    expect(stub.lastFingerprint, 'fp');
  });

  test('send forwards an explicit via address verbatim', () async {
    // The bare IP must survive the service hop unchanged: the engine pairs it
    // with the port from the device record, so nothing may append or reformat.
    final stub = _StubClient();
    final service = PrivetService(stub);
    await service.send(['a.txt'], 'fp', via: '10.29.210.120');
    expect(stub.lastVia, '10.29.210.120');
  });

  test('send without via leaves the address override unset', () async {
    final stub = _StubClient();
    final service = PrivetService(stub);
    await service.send(['a.txt'], 'fp');
    expect(stub.lastVia, isNull,
        reason: 'an absent override must not become an empty string');
  });
}
