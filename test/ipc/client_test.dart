import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/client.dart';
import 'package:privet_app/services/ipc/transport.dart';

Map<String, dynamic> _msg(String type, Map<String, dynamic> body) =>
    {'type': type, ...body};

Map<String, dynamic> _payload(String kind, Map<String, dynamic> data) =>
    {'kind': kind, 'data': data};

Map<String, dynamic> _status(String id) =>
    _msg('response', {
      'request_id': id,
      'payload': _payload('status', {
        'protocol_version': 1,
        'daemon_version': '0.1.0',
        'session_id': 'sess-A',
        'device_fingerprint': 'fp',
        'quic_addr': 'q',
        'tcp_addr': 't',
        'active_transfers': <String>[],
      }),
    });

void main() {
  test('connect performs status and replay; dedupes events', () async {
    final transport = MemoryTransport((requests) {
      final replies = <Map<String, dynamic>>[];
      for (final req in requests) {
        final id = req['request_id'];
        final method = (req['request'] as Map<String, dynamic>)['method'];
        switch (method) {
          case 'get_status':
            replies.add(_status(id as String));
            break;
          case 'subscribe_events':
            // Replay sequences after the cursor (2): seq 3 only. `oldest` is 1
            // so there is no gap; live events arrive as separate frames.
            replies.add(_msg('response', {
              'request_id': id,
              'payload': _payload('event_replay', {
                'events': [
                  {
                    'sequence': 3,
                    'event': {
                      'name': 'device_discovered',
                      'data': {
                        'device_fingerprint': 'fp2',
                        'device_name': 'phone',
                      },
                    },
                  },
                ],
                'oldest_available': 1,
                'latest': 3,
              }),
            }));
            break;
        }
      }
      return replies;
    });

    final client = PrivetIpcClient(transport);
    final session = await client.connect(afterSequence: 2);
    expect(session.status.sessionId, 'sess-A');
    expect(session.replay, hasLength(1));
    expect(session.replay.single, isA<DeviceDiscoveredEvent>());
    expect(session.gap, isFalse);
    expect(session.sessionChanged, isTrue); // no previous session

    // A live event with sequence 3 (already in replay) is dropped; seq 4 passes.
    final live = <dynamic>[];
    final sub = client.events.listen(live.add);
    transport.inject(_msg('event', {
      'sequence': 3,
      'event': {'name': 'device_lost', 'data': {'device_fingerprint': 'fp2'}},
    }));
    transport.inject(_msg('event', {
      'sequence': 4,
      'event': {'name': 'device_lost', 'data': {'device_fingerprint': 'fp2'}},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    expect(live, hasLength(1));
    expect((live.single as DeviceLostEvent).sequence, 4);
    await client.close();
  });

  test('call surfaces daemon errors as PrivetIpcException', () async {
    final transport = MemoryTransport((requests) {
      final req = requests.single;
      final id = req['request_id'] as String;
      final method = (req['request'] as Map<String, dynamic>)['method'];
      switch (method) {
        case 'get_status':
          return [_status(id)];
        case 'subscribe_events':
          return [
            _msg('response', {
              'request_id': id,
              'payload': _payload('event_replay', {
                'events': <dynamic>[],
                'oldest_available': null,
                'latest': 0,
              }),
            }),
          ];
        default:
          return [
            _msg('response', {
              'request_id': id,
              'error': {'code': 'not_paired', 'message': 'pair me first'},
            }),
          ];
      }
    });
    final client = PrivetIpcClient(transport);
    await client.connect();
    await expectLater(
      client.send(['a'], 'fp'),
      throwsA(
          predicate((e) => e is PrivetIpcException && e.code == 'not_paired')),
    );
    await client.close();
  });
}
