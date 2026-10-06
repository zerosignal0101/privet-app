// The `resolve_address` wire format, checked against the bytes a real daemon
// sent.
//
// Every other test in this area builds its payload as a Dart map, which proves
// only that the app agrees with itself. These two are the real captures, and
// `ResolvedAddressDto` is strict about unknown fields by design, so they fail
// the moment either side drifts: a field renamed, dropped, or retyped on the
// daemon shows up here as a parse error instead of as an address that quietly
// resolves to nothing on one user's machine.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/dto.dart';

import '../support/resolve_fixtures.dart';

void main() {
  group('ResolvedAddressDto from a real capture', () {
    test('parses a trusted answer exactly as the daemon sent it', () {
      final dto =
          ResolvedAddressDto.fromJson(jsonDecode(resolveTrustedJson) as Map<String, dynamic>);

      expect(dto.found, isTrue);
      expect(dto.trusted, isTrue);
      expect(dto.deviceName, 'Xiaomi 2410DPN6CC LXR');
      expect(dto.deviceFingerprint,
          '828312c176632a80f48fa41e57e48655af6d97a838e86b9a6ffd9eb7f374feac');
      expect(dto.quicPort, 47808);
      expect(dto.tcpPort, 47808);
    });

    test('parses an untrusted answer exactly as the daemon sent it', () {
      final dto =
          ResolvedAddressDto.fromJson(jsonDecode(resolveUntrustedJson) as Map<String, dynamic>);

      expect(dto.found, isTrue);
      expect(dto.trusted, isFalse);
      expect(dto.deviceName, 'Thinkpad-P15v-LXR');
      expect(dto.deviceFingerprint,
          '89507b08f8f34d7bb77a7b241ebefbe3a037d6c9d33a934e597af93249a6e0a0');
      expect(dto.quicPort, 47808);
      expect(dto.tcpPort, 47808);
    });

    test('the two captures differ in trust, not in shape', () {
      // Same method, same field set: only `trusted` and the identity differ.
      // A parse failure on one capture and not the other would mean the
      // app treats "unknown device" differently from "known device" on the
      // wire, which is exactly the confusion being fixed in the UI.
      final trusted = ResolvedAddressDto.fromJson(resolveTrustedPayload());
      final untrusted = ResolvedAddressDto.fromJson(resolveUntrustedPayload());

      expect(trusted.found, untrusted.found);
      expect(trusted.quicPort, untrusted.quicPort);
      expect(trusted.tcpPort, untrusted.tcpPort);
      expect(trusted.trusted, isNot(untrusted.trusted));
      expect(trusted.deviceFingerprint,
          isNot(untrusted.deviceFingerprint));
    });

    test('a "found: false" answer carries no identity, as the captures imply',
        () {
      // Not a capture (the daemon never sent one during the investigation),
      // but the contract the two captures share: identity is null exactly when
      // nothing answered, which is what keeps the UI from naming a device that
      // is not there.
      final dto = ResolvedAddressDto.fromJson({
        'found': false,
        'device_fingerprint': null,
        'device_name': null,
        'trusted': false,
        'quic_port': 47808,
        'tcp_port': 47808,
      });

      expect(dto.found, isFalse);
      expect(dto.deviceFingerprint, isNull);
      expect(dto.deviceName, isNull);
      expect(dto.trusted, isFalse);
    });

    test('an unknown field is rejected rather than ignored', () {
      // Guards the drift this file is for: a new daemon field must be a loud
      // failure in CI, not a silently dropped value in a shipped app.
      expect(
        () => ResolvedAddressDto.fromJson({
          ...resolveTrustedPayload(),
          'rtt_ms': 12,
        }),
        throwsA(isA<IpcProtocolException>()),
      );
    });
  });
}