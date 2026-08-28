import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/providers/peers.dart';
import 'package:privet_app/state/daemon_state.dart';

import '../support/test_daemon.dart';

Map<String, dynamic> _msg(String type, Map<String, dynamic> body) =>
    {'type': type, ...body};

Map<String, dynamic> _payload(String kind, Object data) =>
    {'kind': kind, 'data': data};

Map<String, dynamic> _ok(String id, String kind, Object data) =>
    _msg('response', {'request_id': id, 'payload': _payload(kind, data)});

Map<String, dynamic> _status(String id) => _ok(id, 'status', {
      'protocol_version': 1,
      'daemon_version': '0.1.0',
      'session_id': 'sess-A',
      'device_fingerprint': 'fp',
      'quic_addr': 'q',
      'tcp_addr': 't',
      'active_transfers': <String>[],
    });

/// Builds a script from a per-method handler map; the connection handshake
/// (get_status + subscribe_events) is answered automatically.
List<Map<String, dynamic>> Function(List<Map<String, dynamic>>) _script(
    Map<String, Map<String, dynamic> Function(String id)> handlers) {
  return (requests) => requests.map((req) {
        final id = req['request_id'] as String;
        final method =
            (req['request'] as Map<String, dynamic>)['method'] as String;
        switch (method) {
          case 'get_status':
            return _status(id);
          case 'subscribe_events':
            return _ok(id, 'event_replay',
                {'events': <dynamic>[], 'oldest_available': null, 'latest': 0});
        }
        final h = handlers[method];
        if (h == null) throw StateError('unexpected method: $method');
        return h(id);
      }).toList();
}

void main() {
  test('peerListProvider upserts on device_discovered and removes on lost',
      () async {
    final daemon = await bootTestDaemon(_script({
      'list_peers': (id) => _ok(id, 'peers', [
            {
              'device_fingerprint': 'fp1',
              'device_name': 'desk',
              'state': 'seen',
              'last_beacon_ms': 0,
              'candidates': <dynamic>[],
            },
          ]),
    }));
    addTearDown(daemon.dispose);

    final n = daemon.container.read(peerListProvider.notifier);
    await n.refresh();
    expect(daemon.container.read(peerListProvider), hasLength(1));

    // A live discovery for a new fingerprint appends it.
    daemon.transport.inject(_msg('event', {
      'sequence': 1,
      'event': {
        'name': 'device_discovered',
        'data': {'device_fingerprint': 'fp2', 'device_name': 'phone'},
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final afterDiscover = daemon.container.read(peerListProvider);
    expect(afterDiscover, hasLength(2));
    expect(afterDiscover.last.deviceFingerprint, 'fp2');
    expect(afterDiscover.last.deviceName, 'phone');

    // A device_lost event removes it.
    daemon.transport.inject(_msg('event', {
      'sequence': 2,
      'event': {
        'name': 'device_lost',
        'data': {'device_fingerprint': 'fp2'},
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(daemon.container.read(peerListProvider), hasLength(1));
  });

  test('scan results never include the device itself', () async {
    final daemon = await bootTestDaemon(_script({
      'list_peers': (id) => _ok(id, 'peers', [
            {
              'device_fingerprint': 'fp', // our own fingerprint (self beacon)
              'device_name': 'me',
              'state': 'seen',
              'last_beacon_ms': 0,
              'candidates': <dynamic>[],
            },
            {
              'device_fingerprint': 'fp1',
              'device_name': 'desk',
              'state': 'seen',
              'last_beacon_ms': 0,
              'candidates': <dynamic>[],
            },
          ]),
    }));
    addTearDown(daemon.dispose);

    final n = daemon.container.read(peerListProvider.notifier);
    // Resolve daemon status first so the provider knows its own fingerprint.
    await daemon.container.read(daemonStatusProvider.future);
    await n.refresh();

    final afterRefresh = daemon.container.read(peerListProvider);
    expect(afterRefresh, hasLength(1));
    expect(afterRefresh.single.deviceFingerprint, 'fp1');

    // A live discovery for our own fingerprint is dropped too.
    daemon.transport.inject(_msg('event', {
      'sequence': 1,
      'event': {
        'name': 'device_discovered',
        'data': {'device_fingerprint': 'fp', 'device_name': 'me'},
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(daemon.container.read(peerListProvider), hasLength(1));

    // A real peer is still added.
    daemon.transport.inject(_msg('event', {
      'sequence': 2,
      'event': {
        'name': 'device_discovered',
        'data': {'device_fingerprint': 'fp2', 'device_name': 'phone'},
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(daemon.container.read(peerListProvider), hasLength(2));
  });

  test('identity and trusted providers read through the service', () async {
    final daemon = await bootTestDaemon(_script({
      'get_identity': (id) => _ok(
          id, 'identity', {'device_fingerprint': 'me', 'device_name': 'mydev'}),
      'list_trusted': (id) => _ok(id, 'trusted', [
            {
              'device_fingerprint': 'tp',
              'device_name': 'friend',
              'trust_state': 'trusted',
              'spki_hex': 'x',
              'first_paired_ts': 1,
              'last_seen_ts': 2,
              'revoked_ts': null,
              'revocation_reason': null,
            },
          ]),
    }));
    addTearDown(daemon.dispose);

    final identity = await daemon.container.read(identityProvider.future);
    expect(identity!.deviceFingerprint, 'me');
    expect(identity.deviceName, 'mydev');

    final trusted = await daemon.container.read(trustedListProvider.future);
    expect(trusted.single.deviceFingerprint, 'tp');
  });
}
