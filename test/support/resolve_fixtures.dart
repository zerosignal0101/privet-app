// Byte-for-byte captures of `resolve_address` answers from a real privet
// daemon, kept as the raw wire text rather than as Dart maps.
//
// Why raw: a fixture written as a Dart map only proves the app agrees with
// itself. These strings are what the daemon actually sent, so parsing them
// fails loudly if a field is renamed, dropped, or retyped on either side — the
// kind of drift that otherwise shows up as an address that resolves to nothing
// on a user's machine and nowhere else.
//
// Source: hermes-workspace/2026-10-06-privet-lan-address-features/evidence/
import 'dart:convert';

/// The `result` object of a `resolve_address` for a device this daemon already
/// trusts (a Xiaomi phone).
const String resolveTrustedJson = '''{
  "device_fingerprint": "828312c176632a80f48fa41e57e48655af6d97a838e86b9a6ffd9eb7f374feac",
  "device_name": "Xiaomi 2410DPN6CC LXR",
  "found": true,
  "quic_port": 47808,
  "tcp_port": 47808,
  "trusted": true
}
''';

/// The same call for a device that answered but is not in this daemon's trust
/// store (a ThinkPad laptop).
const String resolveUntrustedJson = '''{
  "device_fingerprint": "89507b08f8f34d7bb77a7b241ebefbe3a037d6c9d33a934e597af93249a6e0a0",
  "device_name": "Thinkpad-P15v-LXR",
  "found": true,
  "quic_port": 47808,
  "tcp_port": 47808,
  "trusted": false
}
''';

Map<String, dynamic> resolveTrustedPayload() =>
    jsonDecode(resolveTrustedJson) as Map<String, dynamic>;

Map<String, dynamic> resolveUntrustedPayload() =>
    jsonDecode(resolveUntrustedJson) as Map<String, dynamic>;
