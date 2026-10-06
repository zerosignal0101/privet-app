// `list_trusted` records grew an additive `addresses` field — the LAN addresses
// the daemon remembered for a device (written back by the engine after a
// successful transfer, most-recent-first, capped at 8).
//
// Two properties matter here:
//
//  1. When present, the entries parse in engine order and expose the newest one.
//  2. When absent — a daemon predating the field — the parse must still succeed
//     and yield an empty list, not throw. A missing additive field is not a
//     protocol violation, and failing the whole response would empty the Known
//     Devices list, the recipient picker and the send page's address box at
//     once.
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/dto.dart';

Map<String, dynamic> _addr(String ip, int quic, int tcp, int seen) =>
    {'ip': ip, 'quic_port': quic, 'tcp_port': tcp, 'last_seen_ms': seen};

TrustedPeerDto _peer([List<Map<String, dynamic>>? addresses]) =>
    TrustedPeerDto.fromJson({
      'device_fingerprint': 'fp',
      'device_name': 'friend',
      'trust_state': 'Trusted',
      'spki_hex': 'x',
      'first_paired_ts': 1,
      'last_seen_ts': 2,
      'revoked_ts': null,
      'revocation_reason': null,
      'addresses': ?addresses,
    });

void main() {
  group('TrustedPeerDto.addresses', () {
    test('missing field is treated as an empty list (old daemon)', () {
      final peer = _peer();
      expect(peer.addresses, isEmpty);
      expect(peer.latestAddress, isNull);
    });

    test('explicit empty list is an empty list', () {
      final peer = _peer(const []);
      expect(peer.addresses, isEmpty);
      expect(peer.latestAddress, isNull);
    });

    test('parses every address in engine order with its ports', () {
      final peer = _peer([
        _addr('10.29.210.120', 47808, 47808, 3000),
        _addr('192.168.1.7', 47808, 47810, 2000),
        _addr('fe80::1c2b:3d4e', 47808, 47808, 1000),
      ]);

      expect(peer.addresses.length, 3);
      // Order is the engine's, not re-sorted here: the UI relies on the first
      // entry being the most recent.
      expect(peer.addresses.map((a) => a.ip).toList(), [
        '10.29.210.120',
        '192.168.1.7',
        'fe80::1c2b:3d4e',
      ]);
      // QUIC and TCP ports can differ; both are kept.
      expect(peer.addresses[1].quicPort, 47808);
      expect(peer.addresses[1].tcpPort, 47810);
    });

    test('latestAddress is the newest remembered one', () {
      final peer = _peer([
        _addr('10.29.210.120', 47808, 47808, 3000),
        _addr('192.168.1.7', 47808, 47810, 2000),
      ]);
      expect(peer.latestAddress!.ip, '10.29.210.120');
      // The display form carries the port so it is recognisable in a list.
      expect(peer.latestAddress!.dialString, '10.29.210.120:47808');
    });

    test('an IPv6 address renders bracketed', () {
      final peer = _peer([_addr('fe80::1c2b:3d4e', 47808, 47808, 3000)]);
      expect(peer.latestAddress!.dialString, '[fe80::1c2b:3d4e]:47808');
    });

    test('round-trips through toJson including addresses', () {
      final original = _peer([_addr('10.29.210.120', 47808, 47808, 3000)]);
      final again = TrustedPeerDto.fromJson(original.toJson());
      expect(again.addresses.single.ip, '10.29.210.120');
      expect(again.addresses.single.lastSeenMs, 3000);
    });

    test('a malformed entry is still a loud protocol error', () {
      // The tolerance covers a *missing* field only. A present but
      // wrong-shaped entry must fail loudly like every other DTO.
      expect(
        () => _peer([
          {'ip': '10.0.0.1', 'quic_port': '47808', 'tcp_port': 1, 'last_seen_ms': 0}
        ]),
        throwsA(isA<IpcProtocolException>()),
      );
    });
  });
}
