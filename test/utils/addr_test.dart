// The pair-by-address input is a free-text box, so it must accept what a human
// actually types. Before this parser existed the page did `address.split(':')`,
// which silently produced garbage for IPv6 and rejected a bare IP with a port
// that wasn't there. These cases pin the accepted grammar.
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/utils/addr.dart';

void main() {
  group('parseDialString', () {
    test('bare IPv4 uses the default port', () {
      expect(parseDialString('10.29.210.120'),
          (ip: '10.29.210.120', port: 47808));
    });

    test('IPv4 with an explicit port keeps it', () {
      expect(parseDialString('192.168.1.5:1234'), (ip: '192.168.1.5', port: 1234));
    });

    test('honours a non-default defaultPort', () {
      expect(parseDialString('10.0.0.1', defaultPort: 9999),
          (ip: '10.0.0.1', port: 9999));
    });

    test('surrounding whitespace is trimmed', () {
      expect(parseDialString('  10.0.0.1:5000 '), (ip: '10.0.0.1', port: 5000));
    });

    test('bracketed IPv6 with a port is unwrapped', () {
      expect(parseDialString('[fe80::1c2b:3d4e]:47808'),
          (ip: 'fe80::1c2b:3d4e', port: 47808));
    });

    test('bracketed IPv6 without a port uses the default', () {
      expect(parseDialString('[fe80::1c2b:3d4e]'),
          (ip: 'fe80::1c2b:3d4e', port: 47808));
    });

    test('bare IPv6 is not truncated at its colons', () {
      // The old `split(':')` produced host "fe80" here.
      expect(parseDialString('fe80::1c2b:3d4e'),
          (ip: 'fe80::1c2b:3d4e', port: 47808));
      expect(parseDialString('2001:db8::1'), (ip: '2001:db8::1', port: 47808));
    });

    test('rejects empty, unterminated bracket and non-numeric ports', () {
      expect(parseDialString(''), isNull);
      expect(parseDialString('   '), isNull);
      expect(parseDialString('[fe80::1:47808'), isNull);
      expect(parseDialString('10.0.0.1:abc'), isNull);
      expect(parseDialString(':47808'), isNull);
    });
  });

  group('formatDialString', () {
    test('brackets IPv6 only', () {
      expect(formatDialString('10.0.0.1', 47808), '10.0.0.1:47808');
      expect(formatDialString('fe80::1', 47808), '[fe80::1]:47808');
    });
  });

  group('hasExplicitPort', () {
    test('is false when the port is left out', () {
      // An omitted port means "whatever the daemon listens on", which is not the
      // same instruction as a typed 47808: resolve must not be handed the
      // literal as if the user had chosen it.
      expect(hasExplicitPort('10.29.218.79'), isFalse);
      expect(hasExplicitPort('  10.29.218.79  '), isFalse);
      expect(hasExplicitPort('[fe80::1]'), isFalse);
      // A bare IPv6 literal cannot carry a port: a trailing `:47808` is
      // indistinguishable from part of the address.
      expect(hasExplicitPort('fe80::1c2b:3d4e'), isFalse);
      expect(hasExplicitPort('2001:db8::1'), isFalse);
    });

    test('is true when a port is written out', () {
      expect(hasExplicitPort('10.29.218.79:47808'), isTrue);
      expect(hasExplicitPort('10.29.218.79:1234'), isTrue);
      expect(hasExplicitPort('[fe80::1]:47808'), isTrue);
    });

    test('is false for input that is not an address at all', () {
      // Callers parse first, so this only has to avoid claiming a port on
      // garbage; anything else would turn a typo into a dialled port.
      expect(hasExplicitPort(''), isFalse);
      expect(hasExplicitPort('landesk.local'), isFalse);
      expect(hasExplicitPort('10.0.0.1:abc'), isFalse);
    });
  });
}
