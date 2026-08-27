import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/dto.dart';

void main() {
  test('DaemonStatus.fromJson', () {
    final s = DaemonStatus.fromJson(jsonDecode('''
      {"protocol_version":1,"daemon_version":"0.1.0","session_id":"s1",
       "device_fingerprint":"fp","quic_addr":"0.0.0.0:47808",
       "tcp_addr":"0.0.0.0:47810","active_transfers":[]}
    ''') as Map<String, dynamic>);
    expect(s.sessionId, 's1');
    expect(s.activeTransfers, isEmpty);
  });

  test('PeerDto.fromJson with candidates', () {
    final p = PeerDto.fromJson(jsonDecode('''
      {"device_fingerprint":"fp","device_name":"phone","state":"seen",
       "last_beacon_ms":42,"candidates":[
         {"ip":"10.0.0.5","quic_port":47808,"tcp_port":47810,"last_seen_ms":42}
       ]}
    ''') as Map<String, dynamic>);
    expect(p.candidates.single.ip, '10.0.0.5');
  });

  test('HistoryDetailDto.fromJson', () {
    final d = HistoryDetailDto.fromJson(jsonDecode('''
      {"transfer_id":"t-1","direction":"receive","peer_device_fingerprint":null,
       "peer_name":"phone","root_name":"docs","status":"completed",
       "started_ts":1,"finished_ts":2,"files":[
         {"relative_path":"a.txt","absolute_path":"/tmp/s/docs/a.txt",
          "size":10,"status":"completed"}]}
    ''') as Map<String, dynamic>);
    expect(d.files.single.absolutePath, '/tmp/s/docs/a.txt');
  });

  test('unknown fields are rejected', () {
    expect(
      () => DaemonStatus.fromJson(jsonDecode(
              '{"protocol_version":1,"daemon_version":"v","session_id":"s",'
              '"device_fingerprint":"f","quic_addr":"q","tcp_addr":"t",'
              '"active_transfers":[],"surprise":1}')
          as Map<String, dynamic>),
      throwsA(isA<IpcProtocolException>()),
    );
  });
}
