// `get_status` grew an additive `local_addrs` field. Two properties matter here:
//
//  1. When present, the addresses parse in order, with the ports intact, and
//     render as a dial string that round-trips through the pair-by-address
//     parser (that string is what the user copies to the other device).
//  2. When absent — a daemon predating the field — the parse must still
//     succeed and yield an empty list, not throw. A missing additive field is
//     not a protocol violation, and failing the whole status would take down
//     the home page and the pairing QR that reads the same response.
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/dto.dart';
import 'package:privet_app/utils/addr.dart';

Map<String, dynamic> _status(Map<String, dynamic> extra) => {
      'protocol_version': 1,
      'daemon_version': '0.1.0',
      'session_id': 'sess-A',
      'device_fingerprint': 'fp',
      'quic_addr': '0.0.0.0:47808',
      'tcp_addr': '0.0.0.0:47808',
      'active_transfers': <String>[],
      ...extra,
    };

Map<String, dynamic> _addr(String ip, int quic, int tcp) =>
    {'ip': ip, 'quic_port': quic, 'tcp_port': tcp};

void main() {
  group('DaemonStatus.localAddrs', () {
    test('missing field is treated as an empty list (old daemon)', () {
      final status = DaemonStatus.fromJson(_status(const {}));
      expect(status.localAddrs, isEmpty);
    });

    test('explicit empty list is an empty list', () {
      final status =
          DaemonStatus.fromJson(_status({'local_addrs': <dynamic>[]}));
      expect(status.localAddrs, isEmpty);
    });

    test('parses every address in engine order with its ports', () {
      final status = DaemonStatus.fromJson(_status({
        'local_addrs': [
          _addr('10.29.210.120', 47808, 47808),
          _addr('192.168.1.7', 47808, 47810),
          _addr('fe80::1c2b:3d4e', 47808, 47808),
        ],
      }));

      expect(status.localAddrs.length, 3);
      expect(status.localAddrs.map((a) => a.ip).toList(), [
        '10.29.210.120', // IPv4 first, engine order preserved
        '192.168.1.7',
        'fe80::1c2b:3d4e',
      ]);
      // Ports are kept separately — QUIC and TCP may differ.
      expect(status.localAddrs[1].quicPort, 47808);
      expect(status.localAddrs[1].tcpPort, 47810);
    });

    test('round-trips through toJson including local_addrs', () {
      final original = DaemonStatus.fromJson(_status({
        'local_addrs': [_addr('10.29.210.120', 47808, 47808)],
      }));
      final again = DaemonStatus.fromJson(original.toJson());
      expect(again.localAddrs.single.ip, '10.29.210.120');
    });

    test('a malformed entry is still a loud protocol error', () {
      // The tolerant handling covers a *missing* field only. A present but
      // wrong-shaped one must fail loudly like every other DTO.
      expect(
        () => DaemonStatus.fromJson(_status({
          'local_addrs': [
            {'ip': '10.0.0.1', 'quic_port': '47808'}
          ],
        })),
        throwsA(isA<IpcProtocolException>()),
      );
    });
  });

  group('LocalAddrDto.dialString', () {
    test('IPv4 renders ip:port', () {
      expect(
        DaemonStatus.fromJson(_status({
          'local_addrs': [_addr('10.29.210.120', 47808, 47808)],
        })).localAddrs.single.dialString,
        '10.29.210.120:47808',
      );
    });

    test('IPv6 is bracketed so the port stays unambiguous', () {
      final dial = DaemonStatus.fromJson(_status({
        'local_addrs': [_addr('fe80::1c2b:3d4e', 47808, 47808)],
      })).localAddrs.single.dialString;
      expect(dial, '[fe80::1c2b:3d4e]:47808');
    });

    test('what is copied parses back to the same ip and port', () {
      // The copy button puts exactly this string on the clipboard for the user
      // to paste into the other device's pair-by-address box, so it has to
      // survive that parser unchanged.
      for (final ip in ['10.29.210.120', 'fe80::1c2b:3d4e']) {
        final dial = formatDialString(ip, 47808);
        expect(parseDialString(dial), (ip: ip, port: 47808));
      }
    });
  });
}
