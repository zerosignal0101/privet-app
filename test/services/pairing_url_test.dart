import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/pairing_url.dart';

void main() {
  test('build → parse round-trips hosts, full fingerprint, name and code',
      () {
    const fp = '0123456789abcdef0123456789abcdef';
    final url = PairingUrl.build(
      fingerprint: fp,
      deviceName: 'my-device',
      hosts: ['192.168.1.5:47808', '192.168.1.6:47808'],
      code: '123456',
    );

    final parsed = PairingUrl.parse(url)!;
    expect(parsed.hosts, ['192.168.1.5:47808', '192.168.1.6:47808']);
    expect(parsed.fingerprint, fp); // never truncated — daemon matches exactly
    expect(parsed.deviceName, 'my-device');
    expect(parsed.code, '123456');
  });

  test('parse accepts a URL without hosts and without code', () {
    final parsed = PairingUrl.parse(
        'privet://pair?fp=abcdef0123456789&n=phone')!;
    expect(parsed.hosts, isEmpty);
    expect(parsed.fingerprint, 'abcdef0123456789');
    expect(parsed.deviceName, 'phone');
    expect(parsed.code, isNull);
  });

  test('parse rejects non-pairing and missing-fingerprint URLs', () {
    expect(PairingUrl.parse('https://example.com'), isNull);
    expect(PairingUrl.parse('privet://pair?n=no-fingerprint'), isNull);
    expect(PairingUrl.parse('privet://other?fp=abc'), isNull);
  });

  test('URL params are encoded', () {
    final url = PairingUrl.build(
      fingerprint: 'fp',
      deviceName: 'a b&c',
      hosts: ['10.0.0.1:47808'],
      code: '42',
    );
    expect(url, contains('n=a%20b%26c'));
    expect(url, contains('code=42'));
  });
}
