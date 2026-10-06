// The `via` field on `send` is the escape hatch for networks where discovery
// cannot work (AP client isolation, a beacon-blocking VLAN): the user pins the
// recipient to a specific IP.
//
// The contract with the engine is narrow and worth pinning down here:
//
//   * `via` is a **bare IP** — the port is read from the device record, so a
//     ported string is not accepted. The user may still *type* a port, and it
//     must be stripped rather than forwarded.
//   * The input box must not accept junk: a bad address is rejected in the UI,
//     because the daemon refuses it before queueing and a request that cannot
//     succeed should never be sent.
//   * An empty box is valid and means "no override" — the engine then dials the
//     address already in the record. It must never be forced into an address.
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/utils/addr.dart';

void main() {
  group('parseViaAddress — accepted input', () {
    test('a bare IPv4 address passes through unchanged', () {
      final v = parseViaAddress('10.29.210.120');
      expect(v.isValid, isTrue);
      expect(v.ip, '10.29.210.120');
      expect(v.error, isNull);
    });

    test('a bare IPv4 is accepted but a bare IPv4 with a bad port is not', () {
      // Guard against a regression where "anything with a colon parses" would
      // let a typo through as an IP.
      expect(parseViaAddress('10.29.210.120').isValid, isTrue);
      final bad = parseViaAddress('10.29.210.120:notaport');
      expect(bad.isValid, isFalse);
      expect(bad.error, isNotNull);
    });

    test('a typed port is stripped — the engine takes it from the record', () {
      final v = parseViaAddress('10.29.210.120:47808');
      expect(v.isValid, isTrue);
      expect(v.ip, '10.29.210.120',
          reason: 'via must be a bare IP; a port here is not just ignored');
    });

    test('a non-default port is also stripped, not forwarded', () {
      final v = parseViaAddress('10.29.210.120:9999');
      expect(v.isValid, isTrue);
      expect(v.ip, '10.29.210.120');
    });

    test('surrounding whitespace is trimmed', () {
      expect(parseViaAddress('  10.29.210.120  ').ip, '10.29.210.120');
    });

    test('a bare IPv6 literal is accepted', () {
      final v = parseViaAddress('fe80::1c2b:3d4e');
      expect(v.isValid, isTrue);
      expect(v.ip, 'fe80::1c2b:3d4e');
    });

    test('a bracketed IPv6 with port is unwrapped and de-ported', () {
      final v = parseViaAddress('[fe80::1c2b:3d4e]:47808');
      expect(v.isValid, isTrue);
      expect(v.ip, 'fe80::1c2b:3d4e');
    });

    test('a bracketed IPv6 without port is unwrapped', () {
      expect(parseViaAddress('[fe80::1c2b:3d4e]').ip, 'fe80::1c2b:3d4e');
    });

    test('an IPv4-mapped IPv6 form is accepted', () {
      expect(parseViaAddress('::ffff:192.168.1.7').ip, '::ffff:192.168.1.7');
    });

    test('an empty box means "no override", not an error', () {
      for (final input in ['', '   ']) {
        final v = parseViaAddress(input);
        expect(v.isValid, isFalse);
        expect(v.ip, isNull);
        expect(v.error, isNull,
            reason: 'an empty box must not block sending');
      }
    });
  });

  group('parseViaAddress — rejected input', () {
    test('a hostname is rejected — the engine dials an IP', () {
      final v = parseViaAddress('my-laptop.local');
      expect(v.isValid, isFalse);
      expect(v.error, isNotNull);
    });

    test('a non-numeric port is rejected', () {
      final v = parseViaAddress('10.29.210.120:abc');
      expect(v.isValid, isFalse);
      expect(v.error, isNotNull);
    });

    test('an out-of-range IPv4 octet is rejected', () {
      expect(parseViaAddress('999.1.1.1').isValid, isFalse);
    });

    test('too few IPv4 octets is rejected', () {
      expect(parseViaAddress('10.29.210').isValid, isFalse);
    });

    test('a malformed IPv6 literal is rejected', () {
      for (final bad in ['fe80:::1', '12345::1', 'gggg::1', '1:2:3:4:5:6:7:8:9']) {
        expect(parseViaAddress(bad).isValid, isFalse, reason: bad);
      }
    });

    test('an unterminated bracket is rejected', () {
      expect(parseViaAddress('[fe80::1').isValid, isFalse);
    });

    test('plain text is rejected', () {
      final v = parseViaAddress('hello world');
      expect(v.isValid, isFalse);
      expect(v.error, isNotNull);
    });
  });

  group('isValidIpLiteral', () {
    test('accepts well-formed IPv4', () {
      for (final ip in ['0.0.0.0', '10.29.210.120', '255.255.255.255']) {
        expect(isValidIpLiteral(ip), isTrue, reason: ip);
      }
    });

    test('rejects bad IPv4', () {
      for (final ip in ['256.0.0.1', '1.2.3', '1.2.3.4.5', '1.2.3.', 'a.b.c.d']) {
        expect(isValidIpLiteral(ip), isFalse, reason: ip);
      }
    });

    test('accepts well-formed IPv6, including compressed forms', () {
      for (final ip in [
        '::',
        '::1',
        'fe80::1c2b:3d4e',
        '2001:db8:0:0:0:0:2:1',
        '2001:db8::2:1',
        '::ffff:192.168.1.7',
      ]) {
        expect(isValidIpLiteral(ip), isTrue, reason: ip);
      }
    });

    test('rejects bad IPv6', () {
      for (final ip in [
        '12345::1',
        '1:2:3:4:5:6:7:8:9',
        '1:2:3:4:5:6:7',
        'fe80::1::2',
        'gggg::1',
      ]) {
        expect(isValidIpLiteral(ip), isFalse, reason: ip);
      }
    });
  });
}
