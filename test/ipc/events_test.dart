import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/events.dart';
import 'package:privet_app/services/ipc/requests.dart';

void main() {
  test('parses a progress event message', () {
    final e = parseEventMessage(jsonDecode('''
      {"sequence":7,"event":{"name":"transfer_progress",
        "data":{"transfer_id":"t-1","verified_bytes":5,"total_bytes":10}}}
    ''') as Map<String, dynamic>);
    expect(e, isA<TransferProgressEvent>());
    final p = e as TransferProgressEvent;
    expect(p.sequence, 7);
    expect(p.transferId, 't-1');
    expect(p.verifiedBytes, 5);
  });

  test('parses runtime_config_changed with nested config', () {
    final e = parseEventMessage(jsonDecode('''
      {"sequence":8,"event":{"name":"runtime_config_changed",
        "data":{"accept_all_trusted":false,"collision_policy":"rename","save_dir":"/s"}}}
    ''') as Map<String, dynamic>);
    final r = e as RuntimeConfigChangedEvent;
    expect(r.config.collisionPolicy, 'rename');
  });

  test('parses daemon_stopping with empty data', () {
    final e = parseEventMessage(jsonDecode(
            '{"sequence":9,"event":{"name":"daemon_stopping","data":null}}')
        as Map<String, dynamic>);
    expect(e, isA<DaemonStoppingEvent>());
  });

  test('rejects unknown event names', () {
    expect(
      () => parseEventMessage(jsonDecode(
              '{"sequence":1,"event":{"name":"made_up","data":{}}}')
          as Map<String, dynamic>),
      throwsA(isA<IpcProtocolException>()),
    );
  });

  test('request envelopes carry method and params', () {
    final req = reqSend(['C:\\a\\b.txt'], 'fp', asName: 'b')['request']
        as Map<String, dynamic>;
    expect(req['method'], 'send');
    final params = req['params'] as Map<String, dynamic>;
    expect(params['paths'], ['C:\\a\\b.txt']);
    expect(params['device_fingerprint'], 'fp');
    expect(params['as_name'], 'b');
  });
}
