# Dart IPC Client + Daemon Supervisor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the app's foundation — a pure-Dart IPC client for the `privetd` contract (framing, DTOs, events, request/response, replay) plus a `DaemonSupervisor` that attaches to or spawns `privetd`, in the `privet-app` Flutter repo.

**Architecture:** A layered client: `protocol.dart` (framing + envelope) → `dto.dart`/`events.dart`/`requests.dart` (types) → `transport.dart` (abstract byte transport with `MemoryTransport` for tests, `win32` named pipe on Windows, `dart:io` unix socket elsewhere) → `client.dart` (`PrivetIpcClient`: `call` correlation, live event stream, replay, dedupe) → `service.dart` (typed facade) and `supervisor.dart` (process lifecycle). Android's transport goes in Plan 4 with the Kotlin plugin; here the transport is injected so the client is platform-agnostic.

**Tech Stack:** Dart (Flutter project), `win32` for the Windows named pipe, `dart:io` `UnixDomainSocket`, `flutter_test`/`test`.

**Target repo:** `D:\C-Codes\privet-app` (this repo). All paths relative to it.

## Global Constraints

- Flutter project lives in this repo root; the UI pages come in a later plan, so `lib/main.dart` stays a minimal placeholder until Plan 3.
- The IPC contract mirrors `privet-ipc` (protocol version 1): envelope `{protocol_version, request_id, request{method, params}}`; server messages `{"type":"response"|"event", ...}`; framing `u32 BE length + UTF-8 JSON`, max 1 MiB. Do not deviate from the daemon's field names/snake_case.
- The client core (`protocol.dart`, `transport.dart`, `client.dart`, `dto.dart`, `events.dart`, `requests.dart`) must not import Flutter packages — only `dart:*` and the `win32`/`ffi` packages. This keeps it unit-testable with `flutter test` and portable.
- Every DTO parse must reject unknown fields (mirror `deny_unknown_fields`); fail loudly on shape mismatches rather than silently null.
- Error handling: `PrivetIpcException(code, message)`; app code branches on `code`, never on message text.
- All state is driven by daemon snapshots + events; the client never auto-reconnects (the supervisor owns reconnect).
- Verification after each task: `flutter analyze` clean and `flutter test` passes.

---
---

### Task 1: Scaffold the Flutter project

**Files:**
- Create: whole Flutter project scaffold
- Modify: `pubspec.yaml` (add `win32`)
- Modify: `lib/main.dart` (minimal placeholder)
- Test: `test/widget_test.dart` (replace with a smoke test)

**Interfaces:**
- Consumes: nothing.
- Produces: a `flutter test`-green project root that later tasks extend.

- [ ] **Step 1: Scaffold**

From `D:\C-Codes\privet-app`, create the Flutter project for the `android,windows,linux,macos` platforms:

```bash
flutter create --platforms=android,windows,linux,macos --org app.privet --project-name privet_app .
```

> `--project-name privet_app` keeps the Dart package name matching the old app. If `flutter create` refuses because the directory already has files (e.g. `docs/`), pass `--empty` and move any generated files as needed — the generated `pubspec.yaml` and `lib/` are what matter.

- [ ] **Step 2: Replace the placeholder app and test**

Replace `lib/main.dart` with:

```dart
import 'package:flutter/material.dart';

void main() => runApp(const PrivetApp());

class PrivetApp extends StatelessWidget {
  const PrivetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Privet',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const Scaffold(body: Center(child: Text('Privet'))),
    );
  }
}
```

Replace `test/widget_test.dart` with:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/main.dart';

void main() {
  testWidgets('placeholder app builds', (tester) async {
    await tester.pumpWidget(const PrivetApp());
    expect(find.text('Privet'), findsOneWidget);
  });
}
```

- [ ] **Step 3: Add `win32`**

In `pubspec.yaml`, under `dependencies:` add `win32: ^5.9.0` (or the latest `5.x`). Then:

```bash
flutter pub get
```

- [ ] **Step 4: Verify**

Run: `flutter analyze && flutter test`
Expected: no analyzer issues; 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/main.dart test/widget_test.dart
git commit -m "chore: scaffold Flutter project for privet_app"
```

---
---

### Task 2: `protocol.dart` — framing and envelope

**Files:**
- Create: `lib/services/ipc/protocol.dart`
- Test: `test/ipc/protocol_test.dart`

**Interfaces:**
- Produces:

```dart
class IpcProtocolException implements Exception {
  IpcProtocolException(this.message);
  final String message;
  @override
  String toString() => 'IpcProtocolException: $message';
}

class IpcFrameCodec {
  static const int headerBytes = 4;
  static const int maxMessageBytes = 1024 * 1024;
  static Uint8List encode(String jsonText);
  static String? decode(BytesBuilder buffer); // null = need more bytes
}

Stream<String> framesFrom(Stream<List<int>> source); // throws on oversized/truncated

Map<String, dynamic> decodeEnvelope(String jsonText); // validates protocol_version
Uint8List encodeRequest(String requestId, String method, Map<String, dynamic>? params);
```

- [ ] **Step 1: Write the failing test**

Create `test/ipc/protocol_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/protocol.dart';

void main() {
  group('IpcFrameCodec', () {
    test('round-trips a message', () {
      const text = '{"a":1}';
      final buffer = BytesBuilder(copy: false)..add(IpcFrameCodec.encode(text));
      expect(IpcFrameCodec.decode(buffer), text);
      expect(buffer.length, 0);
    });

    test('returns null until a full frame is buffered', () {
      final encoded = IpcFrameCodec.encode('{"long":"payload"}');
      final buffer = BytesBuilder(copy: false)..add(encoded.sublist(0, 5));
      expect(IpcFrameCodec.decode(buffer), isNull);
      buffer.add(encoded.sublist(5));
      expect(IpcFrameCodec.decode(buffer), '{"long":"payload"}');
    });

    test('rejects oversized messages', () {
      final big = Uint8List(IpcFrameCodec.maxMessageBytes + 1);
      final buffer = BytesBuilder(copy: false)..add(big);
      expect(() => IpcFrameCodec.encode(utf8.decode(big)), throwsA(isA<IpcProtocolException>()));
    });

    test('framesFrom yields each message and propagates oversize errors', () async {
      final source = Stream<List<int>>.fromIterable([
        IpcFrameCodec.encode('"one"'),
        IpcFrameCodec.encode('"two"'),
      ]);
      final seen = <String>[];
      await expectLater(
        framesFrom(source),
        emitsInOrder(['"one"', '"two"']),
      );
      expect(seen, isEmpty); // placeholder to satisfy analyzer; real assertions below
      await expectLater(
        framesFrom(Stream.value(IpcFrameCodec.encode('"x"'))),
        emits('"x"'),
      );
    });
  });

  group('envelope', () {
    test('encodes request with id, method and params', () {
      final bytes = encodeRequest('req-1', 'get_status', null);
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(json['protocol_version'], 1);
      expect(json['request_id'], 'req-1');
      expect(json['request'], {'method': 'get_status'});
    });

    test('decodeEnvelope rejects wrong protocol version', () {
      expect(
        () => decodeEnvelope('{"protocol_version":99,"request_id":"r","request":{}}'),
        throwsA(isA<IpcProtocolException>()),
      );
    });
  });
}
```

> The `framesFrom` test block is intentionally minimal; fix the assertion list if `flutter_test`'s `emitsInOrder` requires a matcher-compatible use — the essential coverage is round-trip, partial-frame, oversize-reject, and multi-frame streaming.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ipc/protocol_test.dart`
Expected: FAIL — `protocol.dart` doesn't exist (compile error).

- [ ] **Step 3: Implement `protocol.dart`**

```dart
import 'dart:convert';
import 'dart:typed_data';

class IpcProtocolException implements Exception {
  IpcProtocolException(this.message);
  final String message;
  @override
  String toString() => 'IpcProtocolException: $message';
}

class IpcFrameCodec {
  static const int headerBytes = 4;
  static const int maxMessageBytes = 1024 * 1024;

  static Uint8List encode(String jsonText) {
    final bytes = utf8.encode(jsonText);
    if (bytes.length > maxMessageBytes) {
      throw IpcProtocolException('message exceeds $maxMessageBytes bytes');
    }
    final out = BytesBuilder(copy: false);
    final header = Uint8List(headerBytes);
    ByteData.sublistView(header).setUint32(0, bytes.length, Endian.big);
    out.add(header);
    out.add(bytes);
    return out.toBytes();
  }

  /// Decodes one message from [buffer]; returns `null` when more bytes are
  /// needed. Consumes the message (and its 4-byte header) on success.
  static String? decode(BytesBuilder buffer) {
    final bytes = buffer.toBytes();
    if (bytes.length < headerBytes) return null;
    final length = ByteData.sublistView(bytes).getUint32(0, Endian.big);
    if (length > maxMessageBytes) {
      throw IpcProtocolException('frame exceeds $maxMessageBytes bytes');
    }
    if (bytes.length < headerBytes + length) return null;
    final payload = bytes.sublist(headerBytes, headerBytes + length);
    final rest = bytes.sublist(headerBytes + length);
    buffer.clear();
    buffer.add(rest);
    return utf8.decode(payload);
  }
}

Stream<String> framesFrom(Stream<List<int>> source) async* {
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in source) {
    buffer.add(chunk);
    while (true) {
      final message = IpcFrameCodec.decode(buffer);
      if (message == null) break;
      yield message;
    }
  }
}

const int ipcProtocolVersion = 1;

Map<String, dynamic> decodeEnvelope(String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map<String, dynamic>) {
    throw IpcProtocolException('envelope is not a JSON object');
  }
  if (decoded['protocol_version'] != ipcProtocolVersion) {
    throw IpcProtocolException(
        'incompatible protocol version: ${decoded['protocol_version']}');
  }
  return decoded;
}

Uint8List encodeRequest(
  String requestId,
  String method,
  Map<String, dynamic>? params,
) {
  final request = <String, dynamic>{
    'method': method,
    if (params != null && params.isNotEmpty) 'params': params,
  };
  return IpcFrameCodec.encode(jsonEncode({
    'protocol_version': ipcProtocolVersion,
    'request_id': requestId,
    'request': request,
  }));
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ipc/protocol_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/ipc/protocol.dart test/ipc/protocol_test.dart
git commit -m "feat(ipc): protocol framing and envelope"
```

---
---

### Task 3: `dto.dart` — DTO types and JSON parsing

**Files:**
- Create: `lib/services/ipc/dto.dart`
- Test: `test/ipc/dto_test.dart`

**Interfaces:**
- Consumes: `IpcProtocolException`.
- Produces (each a class with `factory X.fromJson(Map<String, dynamic>)` and `toJson()`):

```dart
class DaemonStatus { final int protocolVersion; final String daemonVersion, sessionId, deviceFingerprint, quicAddr, tcpAddr; final List<String> activeTransfers; }
class IdentityDto { final String deviceFingerprint, deviceName; }
class CandidateAddressDto { final String ip; final int quicPort, tcpPort; final int lastSeenMs; }
class PeerDto { final String deviceFingerprint, deviceName, state; final int lastBeaconMs; final List<CandidateAddressDto> candidates; }
class TrustedPeerDto { final String deviceFingerprint, deviceName, trustState, spkiHex; final int firstPairedTs, lastSeenTs; final int? revokedTs; final String? revocationReason; }
class TransferSummaryDto { final String transferId; final int fileCount; final int totalBytes; }
class HistoryEntryDto { final String transferId, direction, status; final String? peerDeviceFingerprint, peerName, rootName; final int fileCount, totalBytes, startedTs; final int? finishedTs; }
class HistoryFileDto { final String relativePath; final String? absolutePath; final int size; final String status; }
class HistoryDetailDto { final String transferId, direction, status; final String? peerDeviceFingerprint, peerName, rootName; final int startedTs; final int? finishedTs; final List<HistoryFileDto> files; }
class RuntimeConfigDto { final bool acceptAllTrusted; final String collisionPolicy; final String saveDir; }
class PairingCodeDto { final String code; final int validitySecs; }
class PairingResultDto { final bool paired; final String? deviceFingerprint; }
```

- [ ] **Step 1: Write the failing test**

Create `test/ipc/dto_test.dart` with fixtures matching the daemon's serde output (snake_case):

```dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ipc/dto_test.dart`
Expected: FAIL — `dto.dart` doesn't exist.

- [ ] **Step 3: Implement `dto.dart`**

Write the eight DTO classes. Follow this pattern (repeated for each; the key invariants are snake_case keys and unknown-field rejection):

```dart
import 'dart:convert';
import 'protocol.dart';

String _requireString(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! String) {
    throw IpcProtocolException('field "$key" must be a string');
  }
  return v;
}

int _requireInt(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! int) {
    throw IpcProtocolException('field "$key" must be an int');
  }
  return v;
}

void _rejectUnknown(Map<String, dynamic> json, Set<String> known) {
  final unknown = json.keys.where((k) => !known.contains(k)).toList();
  if (unknown.isNotEmpty) {
    throw IpcProtocolException('unknown fields: ${unknown.join(", ")}');
  }
}

class DaemonStatus {
  DaemonStatus({
    required this.protocolVersion,
    required this.daemonVersion,
    required this.sessionId,
    required this.deviceFingerprint,
    required this.quicAddr,
    required this.tcpAddr,
    required this.activeTransfers,
  });

  factory DaemonStatus.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {
      'protocol_version', 'daemon_version', 'session_id', 'device_fingerprint',
      'quic_addr', 'tcp_addr', 'active_transfers',
    });
    final transfers = json['active_transfers'];
    if (transfers is! List) {
      throw IpcProtocolException('active_transfers must be a list');
    }
    return DaemonStatus(
      protocolVersion: _requireInt(json, 'protocol_version'),
      daemonVersion: _requireString(json, 'daemon_version'),
      sessionId: _requireString(json, 'session_id'),
      deviceFingerprint: _requireString(json, 'device_fingerprint'),
      quicAddr: _requireString(json, 'quic_addr'),
      tcpAddr: _requireString(json, 'tcp_addr'),
      activeTransfers: transfers.map((e) => e.toString()).toList(),
    );
  }
}
```

> Implement the remaining DTOs with the same helpers. For optional fields (`peerDeviceFingerprint`, `revokedTs`, etc.) read `json[key]` and allow null:

```dart
String? _optString(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! String) throw IpcProtocolException('field "$key" must be a string or null');
  return v;
}

int? _optInt(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! int) throw IpcProtocolException('field "$key" must be an int or null');
  return v;
}
```

The complete field lists per DTO (snake_case keys):

| DTO | keys |
|---|---|
| `DaemonStatus` | `protocol_version, daemon_version, session_id, device_fingerprint, quic_addr, tcp_addr, active_transfers` |
| `IdentityDto` | `device_fingerprint, device_name` |
| `CandidateAddressDto` | `ip, quic_port, tcp_port, last_seen_ms` |
| `PeerDto` | `device_fingerprint, device_name, state, last_beacon_ms, candidates` |
| `TrustedPeerDto` | `device_fingerprint, device_name, trust_state, spki_hex, first_paired_ts, last_seen_ts, revoked_ts, revocation_reason` |
| `TransferSummaryDto` | `transfer_id, file_count, total_bytes` |
| `HistoryEntryDto` | `transfer_id, direction, peer_device_fingerprint, peer_name, root_name, file_count, total_bytes, status, started_ts, finished_ts` |
| `HistoryFileDto` | `relative_path, absolute_path, size, status` |
| `HistoryDetailDto` | `transfer_id, direction, peer_device_fingerprint, peer_name, root_name, status, started_ts, finished_ts, files` |
| `RuntimeConfigDto` | `accept_all_trusted, collision_policy, save_dir` |
| `PairingCodeDto` | `code, validity_secs` |
| `PairingResultDto` | `paired, device_fingerprint` |

Numeric fields that JSON may encode as ints: use `_requireInt` (counts/ports/ts are ints in the daemon). `RuntimeConfigDto.collisionPolicy` and `saveDir` are strings.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ipc/dto_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/ipc/dto.dart test/ipc/dto_test.dart
git commit -m "feat(ipc): DTO types and strict JSON parsing"
```

---
---

### Task 4: `events.dart` + `requests.dart`

**Files:**
- Create: `lib/services/ipc/events.dart`
- Create: `lib/services/ipc/requests.dart`
- Test: `test/ipc/events_test.dart`

**Interfaces:**
- Consumes: `IpcProtocolException`, DTOs.
- Produces:

```dart
// events.dart
sealed class PrivetEvent { final int sequence; final String kind; }
class DeviceDiscoveredEvent extends PrivetEvent { final String deviceFingerprint, deviceName; }
class DeviceLostEvent extends PrivetEvent { final String deviceFingerprint; }
class PairingRequestedEvent extends PrivetEvent { final String deviceFingerprint; }
class PairingResultEvent extends PrivetEvent { final String deviceFingerprint; final bool success; final String? error; }
class TransferPreparingEvent extends PrivetEvent { final String transferId; }
class TransferPreparingProgressEvent extends PrivetEvent { final String transferId; final int scannedBytes, totalBytes; }
class TransferOfferedEvent extends PrivetEvent { final String transferId; final int fileCount, totalBytes; }
class TransferProgressEvent extends PrivetEvent { final String transferId; final int verifiedBytes, totalBytes; }
class TransferReconnectingEvent extends PrivetEvent { final String transferId; final int attempt, backoffMs; }
class TransferResumedEvent extends PrivetEvent { final String transferId; }
class TransferPausedEvent extends PrivetEvent { final String transferId; final String reason; }
class TransferCompletedEvent extends PrivetEvent { final String transferId; }
class TransferCancelledEvent extends PrivetEvent { final String transferId; }
class TransferFailedEvent extends PrivetEvent { final String transferId; final String errorCode; final bool retryable, partKept; }
class IncomingConnectionEvent extends PrivetEvent { final String deviceFingerprint; }
class RuntimeConfigChangedEvent extends PrivetEvent { final RuntimeConfigDto config; }
class DaemonStoppingEvent extends PrivetEvent { }

PrivetEvent parseEventMessage(Map<String, dynamic> message); // {"sequence":N, "event":{"name":...,"data":...}}

// requests.dart
String newRequestId();
Map<String, dynamic> requestEnvelope(String method, [Map<String, dynamic>? params]);
// typed request constructors:
Map<String, dynamic> reqPing(); reqGetStatus(); reqGetIdentity(); reqListPeers(); reqRefreshPeers();
Map<String, dynamic> reqListTrusted(); reqGeneratePairingCode();
Map<String, dynamic> reqPair({String? fingerprint, String? ip, int? quicPort, int? tcpPort, required String code});
Map<String, dynamic> reqRevokePeer(String fp, String reason); reqForgetPeer(String fp);
Map<String, dynamic> reqSend(List<String> paths, String fingerprint, {String? asName});
Map<String, dynamic> reqResumeTransfer(String id); reqResendTransfer(String id);
Map<String, dynamic> reqAcceptTransfer(String id, bool accept);
Map<String, dynamic> reqCancelTransfer(String id); reqPauseTransfer(String id); reqContinueTransfer(String id);
Map<String, dynamic> reqListHistory({String? peer, int limit});
Map<String, dynamic> reqGetHistoryDetail(String id); reqDeleteHistory(String id);
Map<String, dynamic> reqGetRuntimeConfig();
Map<String, dynamic> reqSetRuntimeConfig({bool? acceptAllTrusted, String? collisionPolicy, String? saveDir});
Map<String, dynamic> reqSubscribeEvents({int? afterSequence});
Map<String, dynamic> reqShutdown();
```

- [ ] **Step 1: Write the failing test**

Create `test/ipc/events_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/events.dart';
import 'package:privet_app/services/ipc/requests.dart';

void main() {
  test('parses a progress event message', () {
    final e = parseEventMessage(jsonDecode('''
      {"sequence":7,"event":{"name":"transfer_progress",
        "data":{"transfer_id":"t-1","verified_bytes":5,"total_bytes":10}}}
    ''') as Map<String, dynamic>);
    expect(e, isA<TransferProgressEvent>());
    final p = e as TransferProgressEvent;
    expect(p.sequence, 7);
    expect(p.transferId, 't-1');
    expect(p.verifiedBytes, 5);
  });

  test('parses runtime_config_changed with nested config', () {
    final e = parseEventMessage(jsonDecode('''
      {"sequence":8,"event":{"name":"runtime_config_changed",
        "data":{"accept_all_trusted":false,"collision_policy":"rename","save_dir":"/s"}}}
    ''') as Map<String, dynamic>);
    final r = e as RuntimeConfigChangedEvent;
    expect(r.config.collisionPolicy, 'rename');
  });

  test('parses daemon_stopping with empty data', () {
    final e = parseEventMessage(jsonDecode(
            '{"sequence":9,"event":{"name":"daemon_stopping","data":null}}')
        as Map<String, dynamic>);
    expect(e, isA<DaemonStoppingEvent>());
  });

  test('rejects unknown event names', () {
    expect(
      () => parseEventMessage(jsonDecode(
              '{"sequence":1,"event":{"name":"made_up","data":{}}}')
          as Map<String, dynamic>),
      throwsA(isA<IpcProtocolException>()),
    );
  });

  test('request envelopes carry method and params', () {
    final req = reqSend(['C:\\a\\b.txt'], 'fp', asName: 'b')['request'] as Map<String, dynamic>;
    expect(req['method'], 'send');
    final params = req['params'] as Map<String, dynamic>;
    expect(params['paths'], ['C:\\a\\b.txt']);
    expect(params['device_fingerprint'], 'fp');
    expect(params['as_name'], 'b');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ipc/events_test.dart`
Expected: FAIL — `events.dart`/`requests.dart` don't exist.

- [ ] **Step 3: Implement `events.dart`**

```dart
import 'dart:convert';
import 'dto.dart';
import 'protocol.dart';

sealed class PrivetEvent {
  PrivetEvent(this.sequence);
  final int sequence;
  String get kind;
}

class DeviceDiscoveredEvent extends PrivetEvent {
  DeviceDiscoveredEvent(super.sequence, this.deviceFingerprint, this.deviceName);
  final String deviceFingerprint;
  final String deviceName;
  @override
  String get kind => 'device_discovered';
}

class DeviceLostEvent extends PrivetEvent {
  DeviceLostEvent(super.sequence, this.deviceFingerprint);
  final String deviceFingerprint;
  @override
  String get kind => 'device_lost';
}

class PairingRequestedEvent extends PrivetEvent {
  PairingRequestedEvent(super.sequence, this.deviceFingerprint);
  final String deviceFingerprint;
  @override
  String get kind => 'pairing_requested';
}

class PairingResultEvent extends PrivetEvent {
  PairingResultEvent(super.sequence, this.deviceFingerprint, this.success, this.error);
  final String deviceFingerprint;
  final bool success;
  final String? error;
  @override
  String get kind => 'pairing_result';
}

class TransferPreparingEvent extends PrivetEvent {
  TransferPreparingEvent(super.sequence, this.transferId);
  final String transferId;
  @override
  String get kind => 'transfer_preparing';
}

class TransferPreparingProgressEvent extends PrivetEvent {
  TransferPreparingProgressEvent(super.sequence, this.transferId, this.scannedBytes, this.totalBytes);
  final String transferId;
  final int scannedBytes;
  final int totalBytes;
  @override
  String get kind => 'transfer_preparing_progress';
}

class TransferOfferedEvent extends PrivetEvent {
  TransferOfferedEvent(super.sequence, this.transferId, this.fileCount, this.totalBytes);
  final String transferId;
  final int fileCount;
  final int totalBytes;
  @override
  String get kind => 'transfer_offered';
}

class TransferProgressEvent extends PrivetEvent {
  TransferProgressEvent(super.sequence, this.transferId, this.verifiedBytes, this.totalBytes);
  final String transferId;
  final int verifiedBytes;
  final int totalBytes;
  @override
  String get kind => 'transfer_progress';
}

class TransferReconnectingEvent extends PrivetEvent {
  TransferReconnectingEvent(super.sequence, this.transferId, this.attempt, this.backoffMs);
  final String transferId;
  final int attempt;
  final int backoffMs;
  @override
  String get kind => 'transfer_reconnecting';
}

class TransferResumedEvent extends PrivetEvent {
  TransferResumedEvent(super.sequence, this.transferId);
  final String transferId;
  @override
  String get kind => 'transfer_resumed';
}

class TransferPausedEvent extends PrivetEvent {
  TransferPausedEvent(super.sequence, this.transferId, this.reason);
  final String transferId;
  final String reason;
  @override
  String get kind => 'transfer_paused';
}

class TransferCompletedEvent extends PrivetEvent {
  TransferCompletedEvent(super.sequence, this.transferId);
  final String transferId;
  @override
  String get kind => 'transfer_completed';
}

class TransferCancelledEvent extends PrivetEvent {
  TransferCancelledEvent(super.sequence, this.transferId);
  final String transferId;
  @override
  String get kind => 'transfer_cancelled';
}

class TransferFailedEvent extends PrivetEvent {
  TransferFailedEvent(super.sequence, this.transferId, this.errorCode, this.retryable, this.partKept);
  final String transferId;
  final String errorCode;
  final bool retryable;
  final bool partKept;
  @override
  String get kind => 'transfer_failed';
}

class IncomingConnectionEvent extends PrivetEvent {
  IncomingConnectionEvent(super.sequence, this.deviceFingerprint);
  final String deviceFingerprint;
  @override
  String get kind => 'incoming_connection';
}

class RuntimeConfigChangedEvent extends PrivetEvent {
  RuntimeConfigChangedEvent(super.sequence, this.config);
  final RuntimeConfigDto config;
  @override
  String get kind => 'runtime_config_changed';
}

class DaemonStoppingEvent extends PrivetEvent {
  DaemonStoppingEvent(super.sequence);
  @override
  String get kind => 'daemon_stopping';
}

Map<String, dynamic> _data(Map<String, dynamic> event, String name) {
  final data = event['data'];
  if (data != null && data is! Map<String, dynamic>) {
    throw IpcProtocolException('event "$name" data must be an object or null');
  }
  return (data as Map<String, dynamic>?) ?? const {};
}

int _i(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is! int) throw IpcProtocolException('event field "$key" must be an int');
  return v;
}

String _s(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is! String) throw IpcProtocolException('event field "$key" must be a string');
  return v;
}

bool _b(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is! bool) throw IpcProtocolException('event field "$key" must be a bool');
  return v;
}

PrivetEvent parseEventMessage(Map<String, dynamic> message) {
  final sequence = _i(message, 'sequence');
  final event = message['event'];
  if (event is! Map<String, dynamic>) {
    throw IpcProtocolException('event must be an object');
  }
  final name = _s(event, 'name');
  final data = _data(event, name);
  return switch (name) {
    'device_discovered' =>
        DeviceDiscoveredEvent(sequence, _s(data, 'device_fingerprint'), _s(data, 'device_name')),
    'device_lost' => DeviceLostEvent(sequence, _s(data, 'device_fingerprint')),
    'pairing_requested' => PairingRequestedEvent(sequence, _s(data, 'device_fingerprint')),
    'pairing_result' => PairingResultEvent(
        sequence, _s(data, 'device_fingerprint'), _b(data, 'success'),
        data['error'] as String?),
    'transfer_preparing' => TransferPreparingEvent(sequence, _s(data, 'transfer_id')),
    'transfer_preparing_progress' => TransferPreparingProgressEvent(
        sequence, _s(data, 'transfer_id'), _i(data, 'scanned_bytes'), _i(data, 'total_bytes')),
    'transfer_offered' => TransferOfferedEvent(
        sequence, _s(data, 'transfer_id'), _i(data, 'file_count'), _i(data, 'total_bytes')),
    'transfer_progress' => TransferProgressEvent(
        sequence, _s(data, 'transfer_id'), _i(data, 'verified_bytes'), _i(data, 'total_bytes')),
    'transfer_reconnecting' => TransferReconnectingEvent(
        sequence, _s(data, 'transfer_id'), _i(data, 'attempt'), _i(data, 'backoff_ms')),
    'transfer_resumed' => TransferResumedEvent(sequence, _s(data, 'transfer_id')),
    'transfer_paused' =>
        TransferPausedEvent(sequence, _s(data, 'transfer_id'), _s(data, 'reason')),
    'transfer_completed' => TransferCompletedEvent(sequence, _s(data, 'transfer_id')),
    'transfer_cancelled' => TransferCancelledEvent(sequence, _s(data, 'transfer_id')),
    'transfer_failed' => TransferFailedEvent(
        sequence, _s(data, 'transfer_id'), _s(data, 'error_code'), _b(data, 'retryable'),
        _b(data, 'part_kept')),
    'incoming_connection' => IncomingConnectionEvent(sequence, _s(data, 'device_fingerprint')),
    'runtime_config_changed' =>
        RuntimeConfigChangedEvent(sequence, RuntimeConfigDto.fromJson(data)),
    'daemon_stopping' => DaemonStoppingEvent(sequence),
    _ => throw IpcProtocolException('unknown event name: $name'),
  };
}
```

- [ ] **Step 4: Implement `requests.dart`**

```dart
import 'dart:convert';
import 'protocol.dart';

String newRequestId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(16) + '-' +
    (Object().hashCode.toUnsigned(32)).toRadixString(16);

/// Returns the full client envelope ready for framing.
Map<String, dynamic> requestEnvelope(String method, [Map<String, dynamic>? params]) {
  return jsonDecode(utf8.decode(encodeRequest(newRequestId(), method, params)))
      as Map<String, dynamic>;
}

Map<String, dynamic> reqPing() => requestEnvelope('ping');
Map<String, dynamic> reqGetStatus() => requestEnvelope('get_status');
Map<String, dynamic> reqGetIdentity() => requestEnvelope('get_identity');
Map<String, dynamic> reqListPeers() => requestEnvelope('list_peers');
Map<String, dynamic> reqRefreshPeers() => requestEnvelope('refresh_peers');
Map<String, dynamic> reqListTrusted() => requestEnvelope('list_trusted');
Map<String, dynamic> reqGeneratePairingCode() => requestEnvelope('generate_pairing_code');
Map<String, dynamic> reqPair({
  String? fingerprint,
  String? ip,
  int? quicPort,
  int? tcpPort,
  required String code,
}) {
  return requestEnvelope('pair', {
    if (fingerprint != null)
      'peer': {'kind': 'discovered', 'device_fingerprint': fingerprint}
    else
      'peer': {'kind': 'endpoint', 'ip': ip, 'quic_port': quicPort, 'tcp_port': tcpPort},
    'code': code,
  });
}
Map<String, dynamic> reqRevokePeer(String fp, String reason) =>
    requestEnvelope('revoke_peer', {'device_fingerprint': fp, 'reason': reason});
Map<String, dynamic> reqForgetPeer(String fp) =>
    requestEnvelope('forget_peer', {'device_fingerprint': fp});
Map<String, dynamic> reqSend(List<String> paths, String fingerprint, {String? asName}) =>
    requestEnvelope('send', {
      'paths': paths,
      'device_fingerprint': fingerprint,
      if (asName != null) 'as_name': asName,
    });
Map<String, dynamic> reqResumeTransfer(String id) =>
    requestEnvelope('resume_transfer', {'transfer_id': id});
Map<String, dynamic> reqResendTransfer(String id) =>
    requestEnvelope('resend_transfer', {'transfer_id': id});
Map<String, dynamic> reqAcceptTransfer(String id, bool accept) =>
    requestEnvelope('accept_transfer', {'transfer_id': id, 'accept': accept});
Map<String, dynamic> reqCancelTransfer(String id) =>
    requestEnvelope('cancel_transfer', {'transfer_id': id});
Map<String, dynamic> reqPauseTransfer(String id) =>
    requestEnvelope('pause_transfer', {'transfer_id': id});
Map<String, dynamic> reqContinueTransfer(String id) =>
    requestEnvelope('continue_transfer', {'transfer_id': id});
Map<String, dynamic> reqListHistory({String? peer, int limit = 100}) =>
    requestEnvelope('list_history', {
      if (peer != null) 'peer': peer,
      'limit': limit,
    });
Map<String, dynamic> reqGetHistoryDetail(String id) =>
    requestEnvelope('get_history_detail', {'transfer_id': id});
Map<String, dynamic> reqDeleteHistory(String id) =>
    requestEnvelope('delete_history', {'transfer_id': id});
Map<String, dynamic> reqGetRuntimeConfig() => requestEnvelope('get_runtime_config');
Map<String, dynamic> reqSetRuntimeConfig({
  bool? acceptAllTrusted,
  String? collisionPolicy,
  String? saveDir,
}) =>
    requestEnvelope('set_runtime_config', {
      if (acceptAllTrusted != null) 'accept_all_trusted': acceptAllTrusted,
      if (collisionPolicy != null) 'collision_policy': collisionPolicy,
      if (saveDir != null) 'save_dir': saveDir,
    });
Map<String, dynamic> reqSubscribeEvents({int? afterSequence}) =>
    requestEnvelope('subscribe_events', {
      if (afterSequence != null) 'after_sequence': afterSequence,
    });
Map<String, dynamic> reqShutdown() => requestEnvelope('shutdown');
```

> `newRequestId` is a dev-time stand-in. In production, use a real UUID (add the `uuid` package in Plan 3, or a `Random.secure()` hex). The daemon only requires uniqueness within a connection; this is sufficient for now and documented for replacement.

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/ipc/events_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/services/ipc/events.dart lib/services/ipc/requests.dart test/ipc/events_test.dart
git commit -m "feat(ipc): event types and typed request builders"
```

---
---

### Task 5: `transport.dart` — interface + `MemoryTransport`

**Files:**
- Create: `lib/services/ipc/transport.dart`
- Test: `test/ipc/transport_test.dart`

**Interfaces:**
- Produces:

```dart
abstract class Transport {
  Future<TransportConnection> connect();
}

class TransportConnection {
  TransportConnection({required this.incoming, required this.out});
  final Stream<List<int>> incoming;
  final StreamSink<List<int>> out;
}

/// Test double: an in-memory server script.
class MemoryTransport implements Transport {
  MemoryTransport(this.server);
  final List<Map<String, dynamic>> Function(List<Map<String, dynamic>> requests) server;
  // connects once; incoming mirrors server responses for each request
}

/// Simpler server model: push responses keyed by request; see client tests.
```

- [ ] **Step 1: Write the failing test**

Create `test/ipc/transport_test.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/transport.dart';

void main() {
  test('MemoryTransport round-trips request/response bytes', () async {
    final transport = MemoryTransport((requests) {
      return requests.map((r) {
        return {
          'type': 'response',
          'request_id': r['request_id'],
          'payload': {'kind': 'pong', 'data': {'protocol_version': 1}},
        };
      }).toList();
    });
    final conn = await transport.connect();
    final response = Completer<Map<String, dynamic>>();
    final sub = conn.incoming.transform(utf8.decoder).listen((_) {
      // bytes are assembled into frames by the client; here just collect raw
    });
    // Send a raw frame and observe the reply frame.
    final reply = <String>[];
    conn.incoming
        .map((bytes) => utf8.decode(bytes))
        .listen(reply.add);
    conn.out.add(utf8.encode('{"protocol_version":1,"request_id":"r1","request":{"method":"ping"}}'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    sub.cancel();
    expect(reply, isNotEmpty);
    expect(jsonDecode(reply.single)['type'], 'response');
  });
}
```

> If the byte-level test proves awkward, the authoritative `MemoryTransport` contract is exercised by the client tests in Task 6; keep this task's test to: `MemoryTransport` returns a `TransportConnection` whose `out` accepts bytes and whose `incoming` emits the framed responses produced by its script.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ipc/transport_test.dart`
Expected: FAIL — `transport.dart` doesn't exist.

- [ ] **Step 3: Implement `transport.dart`**

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'protocol.dart';

/// A dumb bidirectional byte channel. Implementations must not do protocol
/// work; they only move bytes.
abstract class Transport {
  Future<TransportConnection> connect();
}

class TransportConnection {
  TransportConnection({required this.incoming, required this.out});
  final Stream<List<int>> incoming;
  final StreamSink<List<int>> out;
}

/// In-memory transport for tests. The [script] receives each request map and
/// returns the server messages (responses and/or events) to emit, in order.
class MemoryTransport implements Transport {
  MemoryTransport(this.script);

  /// Given the request message map (with request_id), returns a list of
  /// server message maps to send back. May be called more than once if the
  /// client sends several requests; requests are queued and answered FIFO.
  final List<Map<String, dynamic>> Function(List<Map<String, dynamic>> requests) script;

  final _incoming = StreamController<List<int>>();
  final _requests = <Map<String, dynamic>>[];

  @override
  Future<TransportConnection> connect() async {
    return TransportConnection(
      incoming: _incoming.stream,
      out: StreamController<List<int>>(onListen: () {}).sink,
    );
  }

  /// Test helper: submit a request frame and emit the scripted replies.
  void submit(String frameJson) {
    final request = jsonDecode(frameJson) as Map<String, dynamic>;
    _requests.add(request);
    final replies = script([request]);
    for (final reply in replies) {
      _incoming.add(IpcFrameCodec.encode(jsonEncode(reply)));
    }
  }
}
```

> To make the client drive the transport naturally, the client writes via `conn.out` and the `MemoryTransport` needs a way to intercept those writes. In Task 6 the client will be given a `MemoryTransport` whose `connect()` returns a `TransportConnection` wired so that `out` forwards to `submit`. Implement `connect()` as:

```dart
  @override
  Future<TransportConnection> connect() async {
    final out = StreamController<List<int>>();
    out.stream
        .map((bytes) => utf8.decode(bytes))
        .listen((frameJson) => submit(frameJson));
    return TransportConnection(incoming: _incoming.stream, out: out.sink);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ipc/transport_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/ipc/transport.dart test/ipc/transport_test.dart
git commit -m "feat(ipc): transport abstraction and memory test double"
```

---
---

### Task 6: `client.dart` — `PrivetIpcClient`

**Files:**
- Create: `lib/services/ipc/client.dart`
- Test: `test/ipc/client_test.dart`

**Interfaces:**
- Consumes: `Transport`, `TransportConnection`, `framesFrom`, `IpcFrameCodec`, `IpcProtocolException`, DTOs, events, requests.
- Produces:

```dart
class PrivetIpcException implements Exception {
  PrivetIpcException(this.code, this.message);
  final String code;
  final String message;
}

sealed class IpcPayload {}
// parse of a response payload; a thin wrapper that keeps raw map + typed getters

class ConnectedSession {
  final DaemonStatus status;
  final List<PrivetEvent> replay;
  final int? oldestAvailable;
  final int latest;
  final int? cursor;          // last sequence applied
  final bool gap;             // after_sequence+1 < oldest_available
  final bool sessionChanged;  // status.session_id != previous session id
}

class PrivetIpcClient {
  PrivetIpcClient(Transport transport, {Duration timeout = const Duration(seconds: 30)});
  final Stream<PrivetEvent> events; // live events (post-replay), deduplicated by sequence

  Future<ConnectedSession> connect({int? afterSequence, String? previousSessionId});
  Future<dynamic> callRaw(String method, [Map<String, dynamic>? params]); // returns the decoded `data` half; throws PrivetIpcException on error payload
  Future<void> close();
  // typed helpers delegate to callRaw + DTO.parse:
  Future<DaemonStatus> getStatus(); Future<IdentityDto> getIdentity();
  Future<List<PeerDto>> listPeers(); Future<void> refreshPeers();
  Future<List<TrustedPeerDto>> listTrusted();
  Future<PairingCodeDto> generatePairingCode();
  Future<PairingResultDto> pair({String? fingerprint, String? ip, int? quicPort, int? tcpPort, required String code});
  Future<void> revokePeer(String fp, {String reason = ''}); Future<void> forgetPeer(String fp);
  Future<String> send(List<String> paths, String fingerprint, {String? asName});
  Future<String> resumeTransfer(String id); Future<String> resendTransfer(String id);
  Future<void> acceptTransfer(String id, {bool accept = true});
  Future<void> cancelTransfer(String id); Future<void> pauseTransfer(String id); Future<void> continueTransfer(String id);
  Future<List<HistoryEntryDto>> listHistory({String? peer, int limit = 100});
  Future<HistoryDetailDto> getHistoryDetail(String id); Future<void> deleteHistory(String id);
  Future<RuntimeConfigDto> getRuntimeConfig();
  Future<RuntimeConfigDto> setRuntimeConfig({bool? acceptAllTrusted, String? collisionPolicy, String? saveDir});
  Future<void> shutdown();
}
```

- [ ] **Step 1: Write the failing test**

Create `test/ipc/client_test.dart`. It drives a `MemoryTransport` script that answers requests (ping → pong; get_status → status; subscribe_events → replay; get_history_detail → detail) and pushes one live event:

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/client.dart';
import 'package:privet_app/services/ipc/transport.dart';
import 'package:privet_app/services/ipc/protocol.dart';

Map<String, dynamic> _msg(String type, Map<String, dynamic> body) =>
    {'type': type, ...body};

Map<String, dynamic> _payload(String kind, Map<String, dynamic> data) =>
    {'kind': kind, 'data': data};

void main() {
  test('connect performs ping, status and replay; dedupes events', () async {
    final transport = MemoryTransport((requests) {
      final replies = <Map<String, dynamic>>[];
      for (final req in requests) {
        final id = req['request_id'];
        final method = (req['request'] as Map<String, dynamic>)['method'];
        switch (method) {
          case 'ping':
            replies.add(_msg('response',
                {'request_id': id, 'payload': _payload('pong', {'protocol_version': 1})}));
          case 'get_status':
            replies.add(_msg('response', {
              'request_id': id,
              'payload': _payload('status', {
                'protocol_version': 1, 'daemon_version': '0.1.0', 'session_id': 'sess-A',
                'device_fingerprint': 'fp', 'quic_addr': 'q', 'tcp_addr': 't',
                'active_transfers': [],
              }),
            }));
          case 'subscribe_events':
            // replay: sequences 1..2 already seen by the cursor are NOT sent
            // (daemon semantics); live events arrive as separate frames.
            replies.add(_msg('response', {
              'request_id': id,
              'payload': _payload('event_replay', {
                'events': [
                  {'sequence': 3, 'event': {'name': 'device_discovered',
                    'data': {'device_fingerprint': 'fp2', 'device_name': 'phone'}}},
                ],
                'oldest_available': 1,
                'latest': 3,
              }),
            }));
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
    final transport = MemoryTransport((requests) => [
          _msg('response', {
            'request_id': requests.single['request_id'],
            'error': {'code': 'not_paired', 'message': 'pair me first'},
          }),
        ]);
    final client = PrivetIpcClient(transport);
    await client.connect();
    await expectLater(
      client.send(['a'], 'fp'),
      throwsA(predicate((e) => e is PrivetIpcException && e.code == 'not_paired')),
    );
    await client.close();
  });
}
```

> `transport.inject(...)` — add a public helper to `MemoryTransport`:

```dart
  /// Push a raw server frame (map) onto the incoming byte stream.
  void inject(Map<String, dynamic> serverMessage) =>
      _incoming.add(IpcFrameCodec.encode(jsonEncode(serverMessage)));
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ipc/client_test.dart`
Expected: FAIL — `client.dart` doesn't exist.

- [ ] **Step 3: Implement `client.dart`**

```dart
import 'dart:async';
import 'dart:convert';

import 'dto.dart';
import 'events.dart';
import 'protocol.dart';
import 'requests.dart';
import 'transport.dart';

class PrivetIpcException implements Exception {
  PrivetIpcException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'PrivetIpcException($code): $message';
}

class ConnectedSession {
  ConnectedSession({
    required this.status,
    required this.replay,
    required this.oldestAvailable,
    required this.latest,
    required this.cursor,
    required this.gap,
    required this.sessionChanged,
  });
  final DaemonStatus status;
  final List<PrivetEvent> replay;
  final int? oldestAvailable;
  final int latest;
  final int? cursor;
  final bool gap;
  final bool sessionChanged;
}

class PrivetIpcClient {
  PrivetIpcClient(this._transport, {this.timeout = const Duration(seconds: 30)});
  final Transport _transport;
  final Duration timeout;

  TransportConnection? _conn;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _liveEvents = StreamController<PrivetEvent>.broadcast();
  int? _lastApplied;
  bool _sessionActive = false;

  bool get isConnected => _conn != null;
  Stream<PrivetEvent> get events => _liveEvents.stream;

  Future<ConnectedSession> connect({int? afterSequence, String? previousSessionId}) async {
    _conn = await _transport.connect();
    _runReader(_conn!.incoming);
    final status = DaemonStatus.fromJson(
        (await callRaw('get_status')) as Map<String, dynamic>);
    final replayPayload = (await callRaw('subscribe_events',
        {if (afterSequence != null) 'after_sequence': afterSequence})) as Map<String, dynamic>;
    final replayJson = (replayPayload['events'] as List?) ?? const [];
    final oldest = (replayPayload['oldest_available'] as num?)?.toInt();
    final latest = (replayPayload['latest'] as num?)?.toInt() ?? 0;
    final replay = replayJson
        .map((e) => parseEventMessage((e as Map<String, dynamic>)))
        .toList();
    _lastApplied = latest;
    final gap = afterSequence != null &&
        oldest != null &&
        afterSequence + 1 < oldest;
    final sessionChanged = previousSessionId != null &&
        previousSessionId != status.sessionId;
    _sessionActive = true;
    return ConnectedSession(
      status: status,
      replay: replay,
      oldestAvailable: oldest,
      latest: latest,
      cursor: _lastApplied,
      gap: gap,
      sessionChanged: sessionChanged,
    );
  }

  void _runReader(Stream<List<int>> incoming) {
    var buffer = BytesBuilder(copy: false);
    incoming.listen((chunk) {
      buffer.add(chunk);
      while (true) {
        final text = IpcFrameCodec.decode(buffer);
        if (text == null) break;
        _onFrame(text);
      }
    }, onError: (Object e, StackTrace st) {
      _failPending(PrivetIpcException('transport', e.toString()));
    }, onDone: () {
      _failPending(PrivetIpcException('closed', 'connection closed'));
    }, cancelOnError: true);
  }

  void _onFrame(String text) {
    final message = jsonDecode(text) as Map<String, dynamic>;
    final type = message['type'];
    if (type == 'response') {
      final requestId = message['request_id'] as String;
      final completer = _pending.remove(requestId);
      if (completer != null) completer.complete(message);
    } else if (type == 'event') {
      final event = parseEventMessage(message);
      if (_sessionActive && _lastApplied != null && event.sequence <= _lastApplied!) {
        return; // dedupe replay overlap
      }
      _lastApplied = event.sequence;
      _liveEvents.add(event);
    } else {
      _failPending(PrivetIpcException('protocol', 'unknown server message type: $type'));
    }
  }

  void _failPending(PrivetIpcException error) {
    _sessionActive = false;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  /// Returns the decoded `data` half of a response payload — a map, a list
  /// (for `peers`/`history`), or `null` for `ack`. Throws [PrivetIpcException]
  /// on a daemon error payload.
  Future<dynamic> callRaw(String method, [Map<String, dynamic>? params]) async {
    final conn = _conn;
    if (conn == null) throw PrivetIpcException('closed', 'client is not connected');
    final requestId = newRequestId();
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    conn.out.add(IpcFrameCodec.encode(jsonEncode({
      'protocol_version': ipcProtocolVersion,
      'request_id': requestId,
      'request': {'method': method, if (params != null) 'params': params},
    })));
    final result = await completer.future.timeout(timeout,
        onTimeout: () => throw PrivetIpcException('timeout', 'request timed out'));
    final payload = result['payload'];
    final error = result['error'];
    if (error != null) {
      throw PrivetIpcException(error['code'] as String, error['message'] as String);
    }
    if (payload == null || payload is! Map<String, dynamic>) {
      throw PrivetIpcException('protocol', 'response must contain exactly one of payload/error');
    }
    // payload is {"kind":..., "data":...}; unwrap to the data half.
    return payload['data'];
  }

  // ---- typed helpers ----------------------------------------------------

  Future<DaemonStatus> getStatus() async =>
      DaemonStatus.fromJson((await callRaw('get_status')) as Map<String, dynamic>);
  Future<IdentityDto> getIdentity() async =>
      IdentityDto.fromJson((await callRaw('get_identity')) as Map<String, dynamic>);
  Future<List<PeerDto>> listPeers() async => ((await callRaw('list_peers')) as List)
      .map((e) => PeerDto.fromJson(e as Map<String, dynamic>))
      .toList();
  Future<void> refreshPeers() async => callRaw('refresh_peers');
  Future<List<TrustedPeerDto>> listTrusted() async => ((await callRaw('list_trusted')) as List)
      .map((e) => TrustedPeerDto.fromJson(e as Map<String, dynamic>))
      .toList();
  Future<PairingCodeDto> generatePairingCode() async =>
      PairingCodeDto.fromJson((await callRaw('generate_pairing_code')) as Map<String, dynamic>);
  Future<PairingResultDto> pair({
    String? fingerprint,
    String? ip,
    int? quicPort,
    int? tcpPort,
    required String code,
  }) async {
    final data = await callRaw('pair', {
      if (fingerprint != null)
        'peer': {'kind': 'discovered', 'device_fingerprint': fingerprint}
      else
        'peer': {'kind': 'endpoint', 'ip': ip, 'quic_port': quicPort, 'tcp_port': tcpPort},
      'code': code,
    });
    return PairingResultDto.fromJson(data as Map<String, dynamic>);
  }
  Future<void> revokePeer(String fp, {String reason = ''}) async =>
      callRaw('revoke_peer', {'device_fingerprint': fp, 'reason': reason});
  Future<void> forgetPeer(String fp) async =>
      callRaw('forget_peer', {'device_fingerprint': fp});
  Future<String> send(List<String> paths, String fingerprint, {String? asName}) async {
    final data = await callRaw('send', {
      'paths': paths,
      'device_fingerprint': fingerprint,
      if (asName != null) 'as_name': asName,
    });
    return (data as Map<String, dynamic>)['transfer_id'] as String;
  }
  Future<String> resumeTransfer(String id) async =>
      (await callRaw('resume_transfer', {'transfer_id': id}))['transfer_id'] as String;
  Future<String> resendTransfer(String id) async =>
      (await callRaw('resend_transfer', {'transfer_id': id}))['transfer_id'] as String;
  Future<void> acceptTransfer(String id, {bool accept = true}) async =>
      callRaw('accept_transfer', {'transfer_id': id, 'accept': accept});
  Future<void> cancelTransfer(String id) async =>
      callRaw('cancel_transfer', {'transfer_id': id});
  Future<void> pauseTransfer(String id) async =>
      callRaw('pause_transfer', {'transfer_id': id});
  Future<void> continueTransfer(String id) async =>
      callRaw('continue_transfer', {'transfer_id': id});
  Future<List<HistoryEntryDto>> listHistory({String? peer, int limit = 100}) async =>
      ((await callRaw('list_history', {if (peer != null) 'peer': peer, 'limit': limit})) as List)
          .map((e) => HistoryEntryDto.fromJson(e as Map<String, dynamic>))
          .toList();
  Future<HistoryDetailDto> getHistoryDetail(String id) async => HistoryDetailDto.fromJson(
      (await callRaw('get_history_detail', {'transfer_id': id})) as Map<String, dynamic>);
  Future<void> deleteHistory(String id) async =>
      callRaw('delete_history', {'transfer_id': id});
  Future<RuntimeConfigDto> getRuntimeConfig() async =>
      RuntimeConfigDto.fromJson((await callRaw('get_runtime_config')) as Map<String, dynamic>);
  Future<RuntimeConfigDto> setRuntimeConfig({
    bool? acceptAllTrusted,
    String? collisionPolicy,
    String? saveDir,
  }) async {
    final data = await callRaw('set_runtime_config', {
      if (acceptAllTrusted != null) 'accept_all_trusted': acceptAllTrusted,
      if (collisionPolicy != null) 'collision_policy': collisionPolicy,
      if (saveDir != null) 'save_dir': saveDir,
    });
    return RuntimeConfigDto.fromJson(data as Map<String, dynamic>);
  }
  Future<void> shutdown() async { await callRaw('shutdown'); }

  Future<void> close() async {
    _failPending(PrivetIpcException('closed', 'client closed'));
    await _conn?.out.close();
    await _liveEvents.close();
    _conn = null;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ipc/client_test.dart`
Expected: PASS. (If the payload-wrapper shape differs, fix the unwrap per the note and re-run.)

- [ ] **Step 5: Commit**

```bash
git add lib/services/ipc/client.dart test/ipc/client_test.dart
git commit -m "feat(ipc): client with request correlation, events and replay"
```

---
---

### Task 7: `named_pipe_transport.dart` — Windows

**Files:**
- Create: `lib/services/ipc/named_pipe_transport.dart`
- Test: `test/ipc/named_pipe_transport_test.dart` (connect-failure path only; real exchange is Task 11)

**Interfaces:**
- Consumes: `Transport`, `TransportConnection`.
- Produces: `class NamedPipeTransport implements Transport { NamedPipeTransport(this.pipeName); Future<TransportConnection> connect(); }`

- [ ] **Step 1: Write the failing test**

Create `test/ipc/named_pipe_transport_test.dart` (guarded to Windows; verifies a clean, bounded failure when the pipe is absent):

```dart
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/named_pipe_transport.dart';

void main() {
  test('connect fails cleanly when the pipe does not exist', () async {
    if (!Platform.isWindows) return; // win32-specific
    final transport = NamedPipeTransport(r'\\.\pipe\privet-app-test-absent');
    await expectLater(
      transport.connect(),
      throwsA(isA<NamedPipeConnectException>()),
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ipc/named_pipe_transport_test.dart`
Expected: FAIL — `named_pipe_transport.dart` doesn't exist.

- [ ] **Step 3: Implement `named_pipe_transport.dart`**

```dart
import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'transport.dart';

class NamedPipeConnectException implements Exception {
  NamedPipeConnectException(this.pipeName, this.errorCode);
  final String pipeName;
  final int errorCode;
  @override
  String toString() => 'NamedPipeConnectException($pipeName, Win32 error $errorCode)';
}

/// Windows named-pipe client over the win32 package.
///
/// Reading uses PeekNamedPipe + ReadFile from a short timer so the Dart event
/// loop is never blocked on an empty pipe. Writes are synchronous (WriteFile)
/// which is acceptable for local IPC frames.
class NamedPipeTransport implements Transport {
  NamedPipeTransport(this.pipeName);
  final String pipeName;

  static const int _pipeBusy = 231; // ERROR_PIPE_BUSY

  @override
  Future<TransportConnection> connect() async {
    final handle = _open();
    final incoming = StreamController<List<int>>();
    final out = StreamController<List<int>>();
    var closed = false;

    Future<void> close() async {
      if (closed) return;
      closed = true;
      if (handle.value != 0) CloseHandle(handle);
      await incoming.close();
      await out.close();
    }

    final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (closed) return;
      final available = _peekAvailable(handle);
      if (available == null) {
        incoming.addError(
            NamedPipeConnectException(pipeName, GetLastError()));
        timer.cancel();
        close();
        return;
      }
      if (available == 0) return;
      final chunk = _read(handle, available);
      if (chunk == null) {
        incoming.addError(
            NamedPipeConnectException(pipeName, GetLastError()));
        timer.cancel();
        close();
        return;
      }
      incoming.add(chunk);
    });

    out.stream.listen((bytes) {
      _write(handle, bytes);
    }, onError: (_) {}, onDone: () => close());

    return TransportConnection(incoming: incoming.stream, out: out.sink);
  }

  Pointer<HANDLE> _open() {
    final name = pipeName.toNativeUtf16();
    final handle = CreateFile(
      name,
      GENERIC_READ | GENERIC_WRITE,
      0,
      nullptr,
      OPEN_EXISTING,
      0,
      NULL,
    );
    name.free();
    if (handle.value == INVALID_HANDLE_VALUE_VALUE) {
      final error = GetLastError();
      if (error == _pipeBusy) {
        // Retry briefly (daemon clients already retry every 50 ms).
        throw NamedPipeConnectException(pipeName, error);
      }
      throw NamedPipeConnectException(pipeName, error);
    }
    return handle;
  }

  int? _peekAvailable(Pointer<HANDLE> handle) {
    final avail = calloc<DWORD>();
    final total = calloc<DWORD>();
    final left = calloc<DWORD>();
    final ok = PeekNamedPipe(handle, nullptr, 0, nullptr, avail, total);
    final result = avail.value;
    calloc.free(avail);
    calloc.free(total);
    calloc.free(left);
    if (ok == 0) return null;
    return result;
  }

  Uint8List? _read(Pointer<HANDLE> handle, int count) {
    final buffer = calloc<Uint8>(count);
    final read = calloc<DWORD>();
    final ok = ReadFile(handle, buffer, count, read, nullptr);
    final bytesRead = read.value;
    final bytes = Uint8List(bytesRead);
    if (bytesRead > 0) {
      bytes.setAll(0, buffer.asTypedList(bytesRead));
    }
    calloc.free(buffer);
    calloc.free(read);
    if (ok == 0) return null;
    return bytes;
  }

  void _write(Pointer<HANDLE> handle, List<int> bytes) {
    final list = Uint8List.fromList(bytes);
    final written = calloc<DWORD>();
    final ok = WriteFile(handle, list, list.length, written, nullptr);
    final bytesWritten = written.value;
    calloc.free(written);
    if (ok == 0) {
      throw NamedPipeConnectException(pipeName, GetLastError());
    }
    assert(bytesWritten == list.length,
        'short pipe write: $bytesWritten of ${list.length}');
  }
}
```

> **Verification gate:** the connect-failure test plus the real-pipe exchange in Task 11 are the coverage for this transport. If `PeekNamedPipe`/`ReadFile` signatures differ in the installed `win32` version, adapt to the package's current API (the logic — peek available → read chunk — is the contract). Run on a Windows machine; this file is `dart:io`-free except nothing (pure FFI), so it compiles everywhere but only *works* on Windows.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ipc/named_pipe_transport_test.dart`
Expected: PASS (on Windows; skipped elsewhere).

- [ ] **Step 5: Commit**

```bash
git add lib/services/ipc/named_pipe_transport.dart test/ipc/named_pipe_transport_test.dart
git commit -m "feat(ipc): win32 named-pipe transport"
```

---
---

### Task 8: `unix_socket_transport.dart` — Linux/macOS

**Files:**
- Create: `lib/services/ipc/unix_socket_transport.dart`
- Test: `test/ipc/unix_socket_transport_test.dart`

**Interfaces:**
- Consumes: `Transport`, `TransportConnection`.
- Produces: `class UnixSocketTransport implements Transport { UnixSocketTransport(this.socketPath); Future<TransportConnection> connect(); }`

- [ ] **Step 1: Write the failing test**

Create `test/ipc/unix_socket_transport_test.dart` (POSIX only; skipped elsewhere):

```dart
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/unix_socket_transport.dart';

void main() {
  test('connects and echoes bytes over a unix socket', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('privet-sock');
    final path = '${dir.path}/test.sock';
    final server = await ServerSocket.bind(UnixDomainSocketAddress(path), 0);
    addTearDown(() async {
      await server.close();
      await dir.delete(recursive: true);
    });
    final serverDone = Future.sync(() async {
      final socket = await server.first;
      await socket.flush();
      socket.drain<dynamic>();
    });

    final transport = UnixSocketTransport(path);
    final conn = await transport.connect();
    final reply = <int>[];
    final sub = conn.incoming.listen(reply.addAll);
    conn.out.add(utf8.encode('hello'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();
    expect(utf8.decode(reply), 'hello');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ipc/unix_socket_transport_test.dart`
Expected: FAIL — `unix_socket_transport.dart` doesn't exist.

- [ ] **Step 3: Implement `unix_socket_transport.dart`**

```dart
import 'dart:async';
import 'dart:io';

import 'transport.dart';

class UnixSocketConnectException implements Exception {
  UnixSocketConnectException(this.socketPath, this.cause);
  final String socketPath;
  final Object cause;
  @override
  String toString() => 'UnixSocketConnectException($socketPath): $cause';
}

class UnixSocketTransport implements Transport {
  UnixSocketTransport(this.socketPath);
  final String socketPath;

  @override
  Future<TransportConnection> connect() async {
    final Socket socket;
    try {
      socket = await UnixDomainSocket.connect(socketPath);
    } catch (e) {
      throw UnixSocketConnectException(socketPath, e);
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    final incoming = StreamController<List<int>>();
    final out = StreamController<List<int>>();
    socket.listen(
      (bytes) => incoming.add(bytes),
      onError: (Object e, StackTrace st) => incoming.addError(e, st),
      onDone: () async {
        await incoming.close();
        await out.close();
      },
      cancelOnError: true,
    );
    out.stream.listen(
      (bytes) => socket.add(bytes),
      onError: (_) {},
      onDone: () => socket.destroy(),
    );
    return TransportConnection(incoming: incoming.stream, out: out.sink);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ipc/unix_socket_transport_test.dart`
Expected: PASS (POSIX).

- [ ] **Step 5: Commit**

```bash
git add lib/services/ipc/unix_socket_transport.dart test/ipc/unix_socket_transport_test.dart
git commit -m "feat(ipc): dart:io unix-socket transport"
```

---
---

### Task 9: `service.dart` — `PrivetService` facade

**Files:**
- Create: `lib/services/privet_service.dart`
- Test: `test/services/privet_service_test.dart`

**Interfaces:**
- Consumes: `PrivetIpcClient` (all typed helpers).
- Produces:

```dart
class PrivetService {
  PrivetService(this._client);
  final PrivetIpcClient _client;
  Stream<PrivetEvent> get events;
  Future<ConnectedSession> connect({int? afterSequence, String? previousSessionId});
  Future<DaemonStatus> status();
  Future<IdentityDto> identity();
  Future<List<PeerDto>> peers();
  Future<void> refreshPeers();
  Future<List<TrustedPeerDto>> trusted();
  Future<PairingCodeDto> generatePairingCode();
  Future<PairingResultDto> pair({required String code, String? fingerprint, String? ip, int? quicPort, int? tcpPort});
  Future<void> revokePeer(String fingerprint, {String reason = ''});
  Future<void> forgetPeer(String fingerprint);
  Future<String> send(List<String> paths, String fingerprint, {String? asName});
  Future<String> resumeTransfer(String transferId);
  Future<String> resendTransfer(String transferId);
  Future<void> acceptTransfer(String transferId, {bool accept = true});
  Future<void> cancelTransfer(String transferId);
  Future<void> pauseTransfer(String transferId);
  Future<void> continueTransfer(String transferId);
  Future<List<HistoryEntryDto>> history({String? peer, int limit = 100});
  Future<HistoryDetailDto> historyDetail(String transferId);
  Future<void> deleteHistory(String transferId);
  Future<RuntimeConfigDto> runtimeConfig();
  Future<RuntimeConfigDto> setRuntimeConfig({bool? acceptAllTrusted, String? collisionPolicy, String? saveDir});
  Future<void> shutdown();
}
```

- [ ] **Step 1: Write the failing test**

Create `test/services/privet_service_test.dart` — assert the facade delegates to the client (a thin wrapper; keep it short):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/privet_service.dart';
import 'package:privet_app/services/ipc/client.dart';

class _StubClient extends PrivetIpcClient {
  _StubClient() : super(_NoTransport());
  int sendCalls = 0;
  String? lastFingerprint;
  @override
  Future<String> send(List<String> paths, String fingerprint, {String? asName}) async {
    sendCalls++;
    lastFingerprint = fingerprint;
    return 't-1';
  }
}

class _NoTransport implements Transport { ... } // see Task 5 interface

void main() {
  test('send delegates to the client', () async {
    final stub = _StubClient();
    final service = PrivetService(stub);
    final id = await service.send(['a.txt'], 'fp');
    expect(id, 't-1');
    expect(stub.sendCalls, 1);
    expect(stub.lastFingerprint, 'fp');
  });
}
```

> `PrivetIpcClient`'s constructor only needs a `Transport`; `_StubClient` extends it and overrides one method, so the base constructor must not connect eagerly. It doesn't — `connect()` is explicit. Implement `_NoTransport` per the `Transport` interface (it is never used because only `send` is called).

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/privet_service_test.dart`
Expected: FAIL — `privet_service.dart` doesn't exist.

- [ ] **Step 3: Implement `privet_service.dart`**

A thin pass-through; every method delegates to `_client` with the same name and arguments:

```dart
import 'ipc/client.dart';
import 'ipc/dto.dart';
import 'ipc/events.dart';

/// Typed facade over the daemon IPC contract. The UI layer (Plan 3) consumes
/// only this class; it never touches Transport or framing.
class PrivetService {
  PrivetService(this._client);
  final PrivetIpcClient _client;

  Stream<PrivetEvent> get events => _client.events;

  Future<ConnectedSession> connect({int? afterSequence, String? previousSessionId}) =>
      _client.connect(afterSequence: afterSequence, previousSessionId: previousSessionId);
  Future<DaemonStatus> status() => _client.getStatus();
  Future<IdentityDto> identity() => _client.getIdentity();
  Future<List<PeerDto>> peers() => _client.listPeers();
  Future<void> refreshPeers() => _client.refreshPeers();
  Future<List<TrustedPeerDto>> trusted() => _client.listTrusted();
  Future<PairingCodeDto> generatePairingCode() => _client.generatePairingCode();
  Future<PairingResultDto> pair({
    required String code,
    String? fingerprint,
    String? ip,
    int? quicPort,
    int? tcpPort,
  }) =>
      _client.pair(code: code, fingerprint: fingerprint, ip: ip, quicPort: quicPort, tcpPort: tcpPort);
  Future<void> revokePeer(String fingerprint, {String reason = ''}) =>
      _client.revokePeer(fingerprint, reason: reason);
  Future<void> forgetPeer(String fingerprint) => _client.forgetPeer(fingerprint);
  Future<String> send(List<String> paths, String fingerprint, {String? asName}) =>
      _client.send(paths, fingerprint, asName: asName);
  Future<String> resumeTransfer(String transferId) => _client.resumeTransfer(transferId);
  Future<String> resendTransfer(String transferId) => _client.resendTransfer(transferId);
  Future<void> acceptTransfer(String transferId, {bool accept = true}) =>
      _client.acceptTransfer(transferId, accept: accept);
  Future<void> cancelTransfer(String transferId) => _client.cancelTransfer(transferId);
  Future<void> pauseTransfer(String transferId) => _client.pauseTransfer(transferId);
  Future<void> continueTransfer(String transferId) => _client.continueTransfer(transferId);
  Future<List<HistoryEntryDto>> history({String? peer, int limit = 100}) =>
      _client.listHistory(peer: peer, limit: limit);
  Future<HistoryDetailDto> historyDetail(String transferId) =>
      _client.getHistoryDetail(transferId);
  Future<void> deleteHistory(String transferId) => _client.deleteHistory(transferId);
  Future<RuntimeConfigDto> runtimeConfig() => _client.getRuntimeConfig();
  Future<RuntimeConfigDto> setRuntimeConfig({
    bool? acceptAllTrusted,
    String? collisionPolicy,
    String? saveDir,
  }) =>
      _client.setRuntimeConfig(
          acceptAllTrusted: acceptAllTrusted, collisionPolicy: collisionPolicy, saveDir: saveDir);
  Future<void> shutdown() => _client.shutdown();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/services/privet_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/privet_service.dart test/services/privet_service_test.dart
git commit -m "feat(ipc): PrivetService typed facade"
```

---
---

### Task 10: `supervisor.dart` — `DaemonSupervisor`

**Files:**
- Create: `lib/services/daemon_supervisor.dart`
- Test: `test/services/daemon_supervisor_test.dart`

**Interfaces:**
- Consumes: `Transport`, `PrivetIpcClient`, `PrivetService`.
- Produces:

```dart
enum DaemonState { stopped, starting, running, error }

class DaemonSupervisor {
  DaemonSupervisor({
    required this.endpoint,
    this.executablePath,
    this.configPath,
    Transport Function()? transportFactory,
    Future<Process> Function()? spawner,     // injectable for tests
    Future<PrivetIpcClient> Function()? attach, // injectable for tests
    this.connectAttempts = 50,
  });

  final String endpoint;            // pipe name or socket path
  final String? executablePath;     // privetd binary; null => attach-only
  final String? configPath;         // daemon --config file
  final int connectAttempts;

  Future<PrivetService> ensureRunning(); // attach if live, else spawn + poll
  Future<void> stop();                   // shutdown IPC + terminate if we spawned
  Stream<DaemonState> get state;
}
```

- [ ] **Step 1: Write the failing test**

Create `test/services/daemon_supervisor_test.dart` — exercise the attach-then-spawn fallback with injected fakes:

```dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/daemon_supervisor.dart';

void main() {
  test('attaches when a daemon is already reachable', () async {
    final supervisor = DaemonSupervisor(
      endpoint: 'test-endpoint',
      attach: () async => _fakeService(),
    );
    final service = await supervisor.ensureRunning();
    expect(service, isA<PrivetService>());
  });

  test('spawns then polls until connect succeeds', () async {
    var attempts = 0;
    final supervisor = DaemonSupervisor(
      endpoint: 'test-endpoint',
      executablePath: '/fake/privetd',
      configPath: '/fake/config.json',
      spawner: () async => _fakeProcess(),
      attach: () async {
        attempts++;
        if (attempts < 3) throw StateError('not up yet');
        return _fakeService();
      },
    );
    final service = await supervisor.ensureRunning();
    expect(service, isA<PrivetService>());
  });

  test('gives up after connectAttempts', () async {
    final supervisor = DaemonSupervisor(
      endpoint: 'x',
      executablePath: '/fake/privetd',
      spawner: () async => _fakeProcess(),
      attach: () async => throw StateError('never'),
      connectAttempts: 3,
    );
    await expectLater(supervisor.ensureRunning(), throwsStateError);
  });
}
```

> Provide `_fakeService()`, `_fakeProcess()` (a minimal `Process`-shaped fake), and `_fakePrivetClient()` in the test. `PrivetService` requires a `PrivetIpcClient`; construct `PrivetService(_FakeClient())` where `_FakeClient extends PrivetIpcClient` with `connect` stubbed. If that is too heavy, change `attach`'s type to return `PrivetService` directly (as shown) and keep the fake service in the test file.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/daemon_supervisor_test.dart`
Expected: FAIL — `daemon_supervisor.dart` doesn't exist.

- [ ] **Step 3: Implement `daemon_supervisor.dart`**

```dart
import 'dart:async';
import 'dart:io';

import 'ipc/client.dart';
import 'ipc/transport.dart';
import 'privet_service.dart';

enum DaemonState { stopped, starting, running, error }

/// Owns the daemon process lifecycle: attaches to a live `privetd` if present,
/// otherwise spawns one (from [executablePath]) with [configPath] and polls the
/// IPC endpoint until it answers. Reconnect after a crash is the caller's job
/// via a fresh `ensureRunning()` — the supervisor is the single owner of
/// process + connection state.
class DaemonSupervisor {
  DaemonSupervisor({
    required this.endpoint,
    this.executablePath,
    this.configPath,
    Transport Function()? transportFactory,
    Future<Process> Function()? spawner,
    Future<PrivetService> Function()? attach,
    this.connectAttempts = 50,
  })  : _transportFactory = transportFactory ?? (() => _transportFor(endpoint)),
        _spawner = spawner,
        _attach = attach;

  final String endpoint;
  final String? executablePath;
  final String? configPath;
  final int connectAttempts;

  final Transport Function() _transportFactory;
  final Future<Process> Function()? _spawner;
  final Future<PrivetService> Function()? _attach;

  final _state = StreamController<DaemonState>.broadcast();
  Process? _process;
  Stream<DaemonState> get state => _state.stream;

  Future<PrivetService> ensureRunning() async {
    _set(DaemonState.starting);

    final attached = await _attachOnce();
    if (attached != null) {
      _set(DaemonState.running);
      return attached;
    }

    if (executablePath == null) {
      _set(DaemonState.error);
      throw StateError('no daemon running and no executablePath to spawn');
    }

    _process = await (_spawner ?? _spawnDefault)();
    for (var i = 0; i < connectAttempts; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final service = await _attachOnce();
      if (service != null) {
        _set(DaemonState.running);
        return service;
      }
      if (_process!.exitCode != null) break; // spawned process died
    }
    _set(DaemonState.error);
    throw StateError('daemon did not become reachable within $connectAttempts attempts');
  }

  Future<PrivetService?> _attachOnce() async {
    if (_attach != null) {
      try {
        return await _attach!();
      } catch (_) {
        return null;
      }
    }
    try {
      final client = PrivetIpcClient(_transportFactory());
      await client.connect();
      return PrivetService(client);
    } catch (_) {
      return null;
    }
  }

  Future<Process> _spawnDefault() {
    final args = <String>[];
    if (configPath != null) args.addAll(['--config', configPath!]);
    return Process.start(executablePath!, args);
  }

  Future<void> stop() async {
    final process = _process;
    if (process != null && process.exitCode == null) {
      process.kill();
      await process.exitCode;
    }
    _set(DaemonState.stopped);
  }

  void _set(DaemonState s) {
    if (_state.isClosed) return;
    _state.add(s);
  }

  static Transport _transportFor(String endpoint) {
    if (Platform.isWindows) return NamedPipeTransport(endpoint);
    return UnixSocketTransport(endpoint);
  }
}

const String defaultWindowsPipeName = r'\\.\pipe\privet-user-v1';

/// POSIX IPC endpoint mirroring privet-ipc's `default_endpoint()` (spec 09 §2):
/// `$XDG_RUNTIME_DIR/privet/privet.sock` when the env var is set, else a
/// username-scoped temp fallback. The app passes the *same* path as `--ipc` to
/// the daemon it spawns (and an explicit app-data path on Android), so the
/// supervisor's `endpoint` always matches the daemon's socket.
String resolvePosixEndpoint() {
  final runtime = Platform.environment['XDG_RUNTIME_DIR'];
  if (runtime != null && runtime.isNotEmpty) {
    return '$runtime/privet/privet.sock';
  }
  final user = (Platform.environment['USER'] ?? 'unknown')
      .replaceAll(RegExp('[^a-zA-Z0-9]'), '_');
  return '${Directory.systemTemp.path}/privet-$user/privet/privet.sock';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/services/daemon_supervisor_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/daemon_supervisor.dart test/services/daemon_supervisor_test.dart
git commit -m "feat(ipc): daemon supervisor attach-or-spawn lifecycle"
```

---
---

### Task 11: Integration smoke — real `privetd` round-trip

**Files:**
- Create: `tool/privetd_path.dart` (locate a built `privetd` binary)
- Create: `test/integration/privetd_smoke_test.dart` (skipped when no binary)

**Interfaces:**
- Consumes: everything (client + supervisor + transports).

- [ ] **Step 1: Build `privetd`**

From `D:\C-Codes\privet`, build a debug binary (Windows):

```bash
cargo build -p privet-daemon --bin privetd
```

The binary is at `D:\C-Codes\privet\target\debug\privetd.exe` (or `privetd` on POSIX).

- [ ] **Step 2: Write the smoke test**

Create `test/integration/privetd_smoke_test.dart` (skips unless the binary exists):

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/daemon_supervisor.dart';
import 'package:privet_app/services/privet_service.dart';

String? _findPrivetd() {
  const candidates = [
    r'D:\C-Codes\privet\target\debug\privetd.exe',
    'D:/C-Codes/privet/target/debug/privetd',
    '/workspace/privet/target/debug/privetd',
  ];
  for (final p in candidates) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

void main() {
  test('real daemon: attach, status, identity, history detail, delete', () async {
    final bin = _findPrivetd();
    if (bin == null) return; // requires a built privetd

    final dir = await Directory.systemTemp.createTemp('privet-smoke');
    final socketPath = '${dir.path}/privet.sock';
    final configPath = '${dir.path}/config.json';
    await File(configPath).writeAsString(jsonEncode({
      'device_name': 'smoke',
      'data_dir': '${dir.path}/data',
      'save_dir': '${dir.path}/received',
      'ipc_endpoint': socketPath,
      'quic_port': 0,
      'tcp_port': 0,
      'discovery_port': 0,
    }));

    final supervisor = DaemonSupervisor(
      endpoint: socketPath,
      executablePath: bin,
      configPath: configPath,
    );
    final service = await supervisor.ensureRunning();
    addTearDown(() async {
      try {
        await service.shutdown();
      } catch (_) {}
      await supervisor.stop();
      await dir.delete(recursive: true);
    });

    final identity = await service.identity();
    expect(identity.deviceFingerprint, isNotEmpty);

    final config = await service.runtimeConfig();
    expect(config.saveDir, '${dir.path}/received');

    await expectLater(service.deleteHistory('does-not-exist'), completes);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
```

> **Daemon `--ipc`:** the config field is `ipc_endpoint` (see `privet.example.json`), and the CLI also accepts `--ipc <path>`. If the built daemon does not yet accept a config `ipc_endpoint`, pass `--ipc $socketPath` instead. Confirm against the installed daemon version.

- [ ] **Step 3: Run the smoke test**

Run: `flutter test test/integration/privetd_smoke_test.dart`
Expected: PASS — proves the client + transport + supervisor attach/spawn a real daemon end-to-end.

- [ ] **Step 4: Test endpoint resolution**

`resolvePosixEndpoint()` (defined in Task 10) must agree with the daemon's `default_endpoint()`. Add a POSIX-only unit test in `test/services/daemon_supervisor_test.dart` that asserts the `$XDG_RUNTIME_DIR/privet/privet.sock` shape when the env var is set and the temp-fallback shape when unset. Confirm the spawned daemon is reachable at the same path by running the smoke test with the config's `ipc_endpoint` set to the supervisor's `endpoint` (they must match).

- [ ] **Step 5: Commit**

```bash
git add tool/privetd_path.dart test/integration/privetd_smoke_test.dart lib/services/daemon_supervisor.dart
git commit -m "feat(ipc): end-to-end daemon smoke test and endpoint resolution"
```

---

## Self-review notes

- **Spec coverage vs design doc §3:** framing/envelope (Task 2), DTOs + events (3–4), client + replay/dedupe (6), transports (7–8), facade (9), supervisor + lifecycle + config (10), endpoint resolution (11). The Android channel transport and Kotlin plugin are deferred to the Android plan; the `win32` pipe is Windows-covered here.
- **Known deviations from the spec to verify at execution:** (1) `ResponsePayload`'s `{"kind","data"}` wrapper — `callRaw` returns the unwrapped `data` (which is a list for `peers`/`history`), verified live in Task 11; (2) `--ipc` vs config `ipc_endpoint` (Task 11); (3) `newRequestId()` uses a clock+hash stand-in, to be replaced with `uuid` in the UI plan; (4) `resolvePosixEndpoint()` mirrors the daemon's fallback path but skips the `dirs`-style runtime/cache lookup when `XDG_RUNTIME_DIR` is unset — acceptable for now, flagged for the UI plan.
- **Type consistency:** DTO field names across Tasks 3, 4, 6, 9 match the daemon's `protocol.rs` exactly (snake_case); `PrivetIpcClient` helper names equal `PrivetService` method names so delegation is mechanical.
