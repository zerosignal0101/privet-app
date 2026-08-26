# Flutter UI Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the old app's UI (3-tab shell, Home feed, send preparation, history, settings, pairing/QR) onto the new daemon model, with Riverpod state driven by `PrivetService` snapshots + events instead of FFI callbacks.

**Architecture:** The UI consumes only `PrivetService` (from Plan 2) and a new `DaemonState` notifier that owns the supervisor lifecycle. Riverpod providers mirror daemon snapshots (`list_peers`, `list_trusted`, `list_history`, `get_runtime_config`) and apply sequenced events into client-side state. The old app's `privet_service.dart`-style facade is replaced by `PrivetService`; the old FFI/isolate/engine layers are gone. Page widgets are ported from the old app with precise deltas; the *data flow* is new.

**Tech Stack:** Flutter, `flutter_riverpod` ^3, `file_picker`, `open_file`, `qr_flutter`, `app_links`, `path_provider`, `shared_preferences`, `package_info_plus`, `image`, `uuid`.

**Target repo:** `D:\C-Codes\privet-app`. The old app to port from: `D:\C-Codes\privet-old\privet_app`.

## Global Constraints

- The UI must not touch `Transport`, framing, or the daemon contract directly — only `PrivetService` and the `DaemonState` provider.
- Recipients are keyed by **fingerprint** (the daemon's `send` takes a trusted fingerprint), never raw address. Manual-address entry is a **pair-by-address** flow (§6.2 of the design spec).
- State is driven by snapshots + events; providers reconcile on `(session_id, sequence)` change/gap exactly as the client reports.
- Dropped (no daemon equivalent): per-device auto-accept star, known-device IP editing, network labels, TCP-fallback toggle, 3-way security mode.
- Verification per task: `flutter analyze` clean, `flutter test` green, and the page renders against a live daemon when integration is required.
- Keep the Riverpod 3 idioms the old app used (`ConsumerWidget`, `NotifierProvider`); do not re-architect state management.

---
---

### Task 1: App bootstrap — `DaemonState` + service wiring

**Files:**
- Create: `lib/state/daemon_state.dart`
- Modify: `lib/main.dart`
- Test: `test/state/daemon_state_test.dart`

**Interfaces:**
- Consumes: `DaemonSupervisor`, `PrivetService` (Plan 2).
- Produces:

```dart
enum DaemonStateKind { stopped, starting, running, error }
class DaemonSnapshot {
  final DaemonStateKind kind;
  final PrivetService? service;
  final String? error;
}

class DaemonStateNotifier extends Notifier<DaemonSnapshot> {
  DaemonSupervisor get _supervisor => ...; // from ref
  Future<void> start();   // ensureRunning + connect/reconcile
  Future<void> stop();
  Future<void> restart(); // stop + start (for config changes)
}
```

- [ ] **Step 1: Write the failing test**

Create `test/state/daemon_state_test.dart`. The notifier is injected with a fake supervisor + service:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/privet_service.dart';
import 'package:privet_app/state/daemon_state.dart';

void main() {
  test('start transitions stopped -> starting -> running', () async {
    final container = ProviderContainer(overrides: [daemonSupervisorProvider.overrideWithValue(FakeSupervisor())]);
    addTearDown(container.dispose);
    final notifier = container.read(daemonStateProvider.notifier);
    final states = <DaemonStateKind>[];
    container.listen(daemonStateProvider, (_, next) => states.add(next.kind));
    await notifier.start();
    expect(states, containsAllInOrder([DaemonStateKind.starting, DaemonStateKind.running]));
    expect(container.read(daemonStateProvider).service, isNotNull);
  });
}
```

> Provide `FakeSupervisor` in the test implementing the same surface `DaemonStateNotifier` uses (`ensureRunning()` returning a `PrivetService` built from a stubbed client, or simply `PrivetService` over a `MemoryTransport` daemon script from Plan 2). If `daemonSupervisorProvider` is not yet defined, define it in `daemon_state.dart` (a `Provider<DaemonSupervisor>` that constructs the real one from platform endpoint + binary discovery).

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/state/daemon_state_test.dart`
Expected: FAIL — files don't exist.

- [ ] **Step 3: Implement `daemon_state.dart`**

```dart
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/daemon_supervisor.dart';
import '../services/ipc/client.dart';
import '../services/privet_service.dart';

enum DaemonStateKind { stopped, starting, running, error }

class DaemonSnapshot {
  DaemonSnapshot({required this.kind, this.service, this.error});
  final DaemonStateKind kind;
  final PrivetService? service;
  final String? error;
}

/// Locate a bundled or adjacent `privetd` binary. Windows: app dir + `privetd.exe`.
/// (Android extraction is Plan 4.) Returns null to run attach-only.
String? discoverPrivetd() {
  if (Platform.isWindows) {
    final candidate = File('${Directory.current.path}/privetd.exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

final daemonEndpointProvider = Provider<String>((ref) {
  if (Platform.isWindows) return defaultWindowsPipeName;
  return resolvePosixEndpoint();
});

final daemonSupervisorProvider = Provider<DaemonSupervisor>((ref) {
  final endpoint = ref.watch(daemonEndpointProvider);
  final bin = discoverPrivetd();
  return DaemonSupervisor(
    endpoint: endpoint,
    executablePath: bin,
    configPath: null, // default config; app-managed config file lands in Plan 4
  );
});

final daemonStateProvider = NotifierProvider<DaemonStateNotifier, DaemonSnapshot>(
  DaemonStateNotifier.new);

class DaemonStateNotifier extends Notifier<DaemonSnapshot> {
  @override
  DaemonSnapshot build() => DaemonSnapshot(kind: DaemonStateKind.stopped);

  Future<void> start() async {
    state = DaemonSnapshot(kind: DaemonStateKind.starting);
    try {
      final service = await ref.read(daemonSupervisorProvider).ensureRunning();
      state = DaemonSnapshot(kind: DaemonStateKind.running, service: service);
    } catch (e) {
      state = DaemonSnapshot(kind: DaemonStateKind.error, error: e.toString());
    }
  }

  Future<void> stop() async {
    await ref.read(daemonSupervisorProvider).stop();
    state = DaemonSnapshot(kind: DaemonStateKind.stopped);
  }

  Future<void> restart() async {
    await stop();
    await start();
  }
}
```

- [ ] **Step 4: Wire `main.dart`**

Replace `lib/main.dart` so the app starts the daemon on launch:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pages/shell_page.dart';
import 'state/daemon_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: PrivetApp()));
}

class PrivetApp extends ConsumerStatefulWidget {
  const PrivetApp({super.key});
  @override
  ConsumerState<PrivetApp> createState() => _PrivetAppState();
}

class _PrivetAppState extends ConsumerState<PrivetApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(daemonStateProvider.notifier).start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final daemon = ref.watch(daemonStateProvider);
    return MaterialApp(
      title: 'Privet',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      debugShowCheckedModeBanner: false,
      home: switch (daemon.kind) {
        DaemonStateKind.starting => const Scaffold(body: Center(child: CircularProgressIndicator())),
        DaemonStateKind.error => _ErrorScreen(error: daemon.error, onRetry: () => ref.read(daemonStateProvider.notifier).start()),
        _ => const ShellPage(),
      },
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({this.error, this.onRetry});
  final String? error;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Daemon unavailable', style: Theme.of(context).textTheme.titleMedium),
            if (error != null) Padding(padding: const EdgeInsets.all(8), child: Text(error!)),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ]),
        ),
      );
}
```

> `shell_page.dart` is ported in Task 6. Until then, use a temporary placeholder shell (a `Scaffold` with a `Center(Text('Privet'))`) so this task compiles.

- [ ] **Step 5: Verify**

Run: `flutter analyze && flutter test`
Expected: clean; existing tests pass (update `test/widget_test.dart` to pump `PrivetApp` with a stubbed supervisor if it now needs one).

- [ ] **Step 6: Commit**

```bash
git add lib/state/daemon_state.dart lib/main.dart test/state/daemon_state_test.dart test/widget_test.dart
git commit -m "feat(ui): daemon state notifier and app bootstrap"
```

---
---

### Task 2: Peer + trusted + identity providers

**Files:**
- Create: `lib/providers/peers.dart`
- Test: `test/providers/peers_test.dart`

**Interfaces:**
- Consumes: `DaemonStateNotifier` (`service`), `PrivetEvent`.
- Produces:

```dart
final identityProvider = FutureProvider<IdentityDto?>((ref) async => service?.identity());
final peerListProvider = NotifierProvider<PeerListNotifier, List<PeerDto>>(PeerListNotifier.new);
final trustedListProvider = FutureProvider<List<TrustedPeerDto>>((ref) async => service?.trusted() ?? const []);
```

- [ ] **Step 1: Write the failing test**

Create `test/providers/peers_test.dart`. Drive a `MemoryTransport` script (Plan 2) that answers `list_peers`/`list_trusted` and pushes `device_discovered`/`device_lost` events; assert the provider upserts and removes:

```dart
test('peerListProvider upserts on device_discovered and removes on lost', () async {
  final container = ProviderContainer(overrides: [daemonStateProvider.overrideWith(buildTestDaemon)]);
  addTearDown(container.dispose);
  // seed an initial peer via the scripted list_peers, then:
  // push device_discovered for a new fingerprint, assert len 2
  // push device_lost for it, assert len 1
});
```

> `buildTestDaemon` overrides the daemon state with a running snapshot whose service wraps a client over a `MemoryTransport`. The script answers `list_peers` ([]), `list_trusted` ([]), and the test calls `ref.read(peerListProvider.notifier).applyEvent(event)` directly (or the notifier subscribes to `service.events` in its `build`). Prefer: the notifier subscribes to `service.events` in `build()` and applies events; the test pushes scripted events through the transport and waits.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/providers/peers_test.dart`
Expected: FAIL — providers don't exist.

- [ ] **Step 3: Implement `lib/providers/peers.dart`**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ipc/dto.dart';
import '../services/ipc/events.dart';
import '../state/daemon_state.dart';

final identityProvider = FutureProvider<IdentityDto?>((ref) async {
  return ref.watch(daemonStateProvider).service?.identity();
});

final peerListProvider =
    NotifierProvider<PeerListNotifier, List<PeerDto>>(PeerListNotifier.new);

class PeerListNotifier extends Notifier<List<PeerDto>> {
  @override
  List<PeerDto> build() {
    final service = ref.watch(daemonStateProvider).service;
    if (service != null) {
      service.events.listen(_onEvent);
    }
    return [];
  }

  Future<void> refresh() async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) return;
    state = await service.peers();
  }

  void _onEvent(PrivetEvent event) {
    switch (event) {
      case DeviceDiscoveredEvent(:final deviceFingerprint, :final deviceName):
        final existing = state.indexWhere((p) => p.deviceFingerprint == deviceFingerprint);
        if (existing >= 0) {
          final peers = [...state];
          peers[existing] = PeerDto(
            deviceFingerprint: deviceFingerprint,
            deviceName: deviceName,
            state: peers[existing].state,
            lastBeaconMs: peers[existing].lastBeaconMs,
            candidates: peers[existing].candidates,
          );
          state = peers;
        } else {
          state = [
            ...state,
            PeerDto(
              deviceFingerprint: deviceFingerprint,
              deviceName: deviceName,
              state: 'seen',
              lastBeaconMs: 0,
              candidates: const [],
            ),
          ];
        }
      case DeviceLostEvent(:final deviceFingerprint):
        state = state.where((p) => p.deviceFingerprint != deviceFingerprint).toList();
      default:
        break;
    }
  }
}

final trustedListProvider = FutureProvider<List<TrustedPeerDto>>((ref) async {
  final service = ref.watch(daemonStateProvider).service;
  return service?.trusted() ?? const [];
});
```

> The subscription in `build()` must not leak — cancel it when the provider disposes. Wrap the `StreamSubscription` in a `ref.onDispose(() => sub.cancel())`.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/providers/peers_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/providers/peers.dart test/providers/peers_test.dart
git commit -m "feat(ui): peer, trusted and identity providers"
```

---
---

### Task 3: Active transfers + pairing providers

**Files:**
- Create: `lib/providers/transfers.dart`
- Create: `lib/providers/pairing.dart`
- Test: `test/providers/transfers_test.dart`, `test/providers/pairing_test.dart`

**Interfaces:**
- Consumes: `PrivetEvent` (all `transfer_*`, `pairing_*`), `PrivetService`.
- Produces:

```dart
enum TransferState { preparing, offered, transferring, reconnecting, paused, completed, failed, cancelled }
class ActiveTransfer {
  final String transferId;
  final String direction;          // 'send' | 'receive'
  final TransferState state;
  final int fileCount, totalBytes, verifiedBytes;
  final String? peerName;
  final String? errorCode;
  final bool retryable;
  final bool isAwaitingAccept;     // offered && receive && !accepted
  double get fraction;             // verified/total
  String? get fileCountText;
}

final activeTransfersProvider = NotifierProvider<ActiveTransfersNotifier, Map<String, ActiveTransfer>>(...);
class ActiveTransfersNotifier extends Notifier<Map<String, ActiveTransfer>> {
  void applyEvent(PrivetEvent event);
  void accept(String id); void reject(String id); void cancel(String id); void pause(String id); void resume(String id);
}

final pairingProvider = NotifierProvider<PairingNotifier, List<PairRequest>>(...);
class PairRequest { final String deviceFingerprint; final String? code; }
```

- [ ] **Step 1: Write the failing tests**

`test/providers/transfers_test.dart` — apply a synthetic event sequence and assert state transitions:

```dart
test('transfer lifecycle: preparing -> offered -> progress -> completed', () {
  final n = ActiveTransfersNotifier();
  n.applyEvent(TransferPreparingEvent(1, 't-1'));
  n.applyEvent(TransferOfferedEvent(2, 't-1', 3, 300));
  expect(n.state['t-1']!.isAwaitingAccept, isTrue);
  n.applyEvent(TransferProgressEvent(3, 't-1', 150, 300));
  expect(n.state['t-1']!.state, TransferState.transferring);
  expect(n.state['t-1']!.fraction, closeTo(0.5, 0.001));
  n.applyEvent(TransferCompletedEvent(4, 't-1'));
  expect(n.state['t-1']!.state, TransferState.completed);
});
```

`test/providers/pairing_test.dart` — `pairing_requested` adds a request, `pairing_result` removes it:

```dart
test('pairing request lifecycle', () {
  final n = PairingNotifier();
  n.applyEvent(PairingRequestedEvent(1, 'fp'));
  expect(n.state, hasLength(1));
  n.applyEvent(PairingResultEvent(2, 'fp', true, null));
  expect(n.state, isEmpty);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/providers/transfers_test.dart test/providers/pairing_test.dart`
Expected: FAIL — notifiers don't exist.

- [ ] **Step 3: Implement `transfers.dart`**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ipc/events.dart';

enum TransferState {
  preparing, offered, transferring, reconnecting, paused, completed, failed, cancelled,
}

class ActiveTransfer {
  ActiveTransfer({
    required this.transferId,
    required this.direction,
    required this.state,
    this.fileCount = 0,
    this.totalBytes = 0,
    this.verifiedBytes = 0,
    this.peerName,
    this.errorCode,
    this.retryable = false,
    this.isAwaitingAccept = false,
  });
  final String transferId;
  final String direction;
  final TransferState state;
  final int fileCount;
  final int totalBytes;
  final int verifiedBytes;
  final String? peerName;
  final String? errorCode;
  final bool retryable;
  final bool isAwaitingAccept;

  double get fraction => totalBytes == 0 ? 0 : verifiedBytes / totalBytes;
}

final activeTransfersProvider = NotifierProvider<ActiveTransfersNotifier, Map<String, ActiveTransfer>>(
    ActiveTransfersNotifier.new);

class ActiveTransfersNotifier extends Notifier<Map<String, ActiveTransfer>> {
  @override
  Map<String, ActiveTransfer> build() {
    final service = ref.watch(daemonStateProvider).service;
    if (service != null) service.events.listen(applyEvent);
    return const {};
  }

  void applyEvent(PrivetEvent event) {
    switch (event) {
      case TransferPreparingEvent(:final transferId):
        state = {...state, transferId: _base(transferId, 'send', TransferState.preparing)};
      case TransferOfferedEvent(:final transferId, :final fileCount, :final totalBytes):
        state = {...state, transferId: _base(transferId, 'receive', TransferState.offered, fileCount, totalBytes, isAwaitingAccept: true)};
      case TransferProgressEvent(:final transferId, :final verifiedBytes, :final totalBytes):
        final cur = state[transferId];
        if (cur == null) return;
        state = {...state, transferId: ActiveTransfer(transferId: transferId, direction: cur.direction, state: TransferState.transferring, fileCount: cur.fileCount, totalBytes: totalBytes, verifiedBytes: verifiedBytes, peerName: cur.peerName)};
      case TransferReconnectingEvent(:final transferId):
        final cur = state[transferId];
        if (cur == null) return;
        state = {...state, transferId: ActiveTransfer(transferId: transferId, direction: cur.direction, state: TransferState.reconnecting, fileCount: cur.fileCount, totalBytes: cur.totalBytes, verifiedBytes: cur.verifiedBytes, peerName: cur.peerName)};
      case TransferPausedEvent(:final transferId):
        final cur = state[transferId];
        if (cur == null) return;
        state = {...state, transferId: ActiveTransfer(transferId: transferId, direction: cur.direction, state: TransferState.paused, fileCount: cur.fileCount, totalBytes: cur.totalBytes, verifiedBytes: cur.verifiedBytes, peerName: cur.peerName)};
      case TransferResumedEvent(:final transferId):
        final cur = state[transferId];
        if (cur == null) return;
        state = {...state, transferId: ActiveTransfer(transferId: transferId, direction: cur.direction, state: TransferState.transferring, fileCount: cur.fileCount, totalBytes: cur.totalBytes, verifiedBytes: cur.verifiedBytes, peerName: cur.peerName)};
      case TransferCompletedEvent(:final transferId):
        state = {...state, transferId: _terminal(transferId, TransferState.completed)};
      case TransferCancelledEvent(:final transferId):
        state = {...state, transferId: _terminal(transferId, TransferState.cancelled)};
      case TransferFailedEvent(:final transferId, :final errorCode, :final retryable):
        state = {...state, transferId: _failed(transferId, errorCode, retryable)};
      default:
        break;
    }
  }

  ActiveTransfer _base(String id, String direction, TransferState st,
          [int files = 0, int bytes = 0, bool isAwaitingAccept = false]) =>
      ActiveTransfer(transferId: id, direction: direction, state: st, fileCount: files,
          totalBytes: bytes, isAwaitingAccept: isAwaitingAccept);

  ActiveTransfer _terminal(String id, TransferState st) {
    final cur = state[id];
    return ActiveTransfer(transferId: id, direction: cur?.direction ?? 'send', state: st,
        fileCount: cur?.fileCount ?? 0, totalBytes: cur?.totalBytes ?? 0,
        verifiedBytes: cur?.verifiedBytes ?? 0, peerName: cur?.peerName);
  }

  ActiveTransfer _failed(String id, String errorCode, bool retryable) {
    final cur = state[id];
    return ActiveTransfer(transferId: id, direction: cur?.direction ?? 'send', state: TransferState.failed,
        fileCount: cur?.fileCount ?? 0, totalBytes: cur?.totalBytes ?? 0,
        verifiedBytes: cur?.verifiedBytes ?? 0, peerName: cur?.peerName,
        errorCode: errorCode, retryable: retryable);
  }

  Future<void> accept(String id) async {
    await ref.read(daemonStateProvider).service?.acceptTransfer(id, accept: true);
    final cur = state[id];
    if (cur != null) {
      state = {...state, id: ActiveTransfer(transferId: id, direction: cur.direction, state: TransferState.transferring, fileCount: cur.fileCount, totalBytes: cur.totalBytes, verifiedBytes: cur.verifiedBytes, peerName: cur.peerName)};
    }
  }
  Future<void> reject(String id) async => ref.read(daemonStateProvider).service?.acceptTransfer(id, accept: false);
  Future<void> cancel(String id) async => ref.read(daemonStateProvider).service?.cancelTransfer(id);
  Future<void> pause(String id) async => ref.read(daemonStateProvider).service?.pauseTransfer(id);
  Future<void> resume(String id) async => ref.read(daemonStateProvider).service?.continueTransfer(id);
}
```

- [ ] **Step 4: Implement `pairing.dart`**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ipc/events.dart';

class PairRequest {
  PairRequest(this.deviceFingerprint);
  final String deviceFingerprint;
}

final pairingProvider = NotifierProvider<PairingNotifier, List<PairRequest>>(PairingNotifier.new);

class PairingNotifier extends Notifier<List<PairRequest>> {
  @override
  List<PairRequest> build() {
    final service = ref.watch(daemonStateProvider).service;
    if (service != null) service.events.listen(applyEvent);
    return const [];
  }

  void applyEvent(PrivetEvent event) {
    switch (event) {
      case PairingRequestedEvent(:final deviceFingerprint):
        if (!state.any((p) => p.deviceFingerprint == deviceFingerprint)) {
          state = [...state, PairRequest(deviceFingerprint)];
        }
      case PairingResultEvent(:final deviceFingerprint):
        state = state.where((p) => p.deviceFingerprint != deviceFingerprint).toList();
      default:
        break;
    }
  }

  Future<void> trust(String fingerprint) async {
    // Pairing completes via `pair` with a code; the daemon persists trust on success.
    // This provider surfaces requests; the actual pairing action lives in the send
    // flow (Task 9) and the pairing dialog (Task 8).
  }
}
```

> The `trust` method is a seam — pairing UX specifics are resolved in Tasks 8–9. Keep the provider focused on surfacing `pairing_requested` events.

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/providers/transfers_test.dart test/providers/pairing_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/providers/transfers.dart lib/providers/pairing.dart test/providers/transfers_test.dart test/providers/pairing_test.dart
git commit -m "feat(ui): active transfers and pairing providers"
```

---
---

### Task 4: History provider (list, detail, delete, resend)

**Files:**
- Create: `lib/providers/history.dart`
- Test: `test/providers/history_test.dart`

**Interfaces:**
- Consumes: `PrivetService` (`history`, `historyDetail`, `deleteHistory`, `resendTransfer`).
- Produces:

```dart
final transferHistoryProvider = NotifierProvider<HistoryNotifier, List<HistoryEntryDto>>(HistoryNotifier.new);
class HistoryNotifier extends Notifier<List<HistoryEntryDto>> {
  Future<void> refresh();
  Future<HistoryDetailDto> detail(String transferId);
  Future<void> delete(String transferId);
  Future<String> resend(String transferId);
}
```

- [ ] **Step 1: Write the failing test**

`test/providers/history_test.dart` — a stubbed service (extend `PrivetService` or use the `MemoryTransport` client):

```dart
test('history provider lists and deletes', () async {
  final container = ProviderContainer(overrides: [daemonStateProvider.overrideWith(testDaemon)]);
  addTearDown(container.dispose);
  final n = container.read(transferHistoryProvider.notifier);
  await n.refresh();
  expect(n.state, isNotEmpty);
  await n.delete(n.state.first.transferId);
  expect(container.read(transferHistoryProvider), isEmpty);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/providers/history_test.dart`
Expected: FAIL — `history.dart` doesn't exist.

- [ ] **Step 3: Implement `lib/providers/history.dart`**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ipc/dto.dart';
import '../state/daemon_state.dart';

final transferHistoryProvider =
    NotifierProvider<HistoryNotifier, List<HistoryEntryDto>>(HistoryNotifier.new);

class HistoryNotifier extends Notifier<List<HistoryEntryDto>> {
  @override
  List<HistoryEntryDto> build() {
    final service = ref.watch(daemonStateProvider).service;
    if (service != null) {
      service.events.listen((event) {
        // transfer_completed / transfer_failed / transfer_cancelled refresh history
        if (event is TransferCompletedEvent ||
            event is TransferFailedEvent ||
            event is TransferCancelledEvent) {
          refresh();
        }
      });
    }
    return const [];
  }

  Future<void> refresh() async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) return;
    state = await service.history(limit: 100);
  }

  Future<HistoryDetailDto> detail(String transferId) async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) throw StateError('daemon not running');
    return service.historyDetail(transferId);
  }

  Future<void> delete(String transferId) async {
    await ref.read(daemonStateProvider).service?.deleteHistory(transferId);
    await refresh();
  }

  Future<String> resend(String transferId) async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) throw StateError('daemon not running');
    return service.resendTransfer(transferId);
  }
}
```

> Import `../services/ipc/events.dart` for the event classes used in `build`.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/providers/history_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/providers/history.dart test/providers/history_test.dart
git commit -m "feat(ui): history provider with detail/delete/resend"
```

---
---

### Task 5: Send-preparation + runtime-config + settings providers

**Files:**
- Create: `lib/providers/send_preparation.dart`
- Create: `lib/providers/settings.dart`
- Test: `test/providers/send_preparation_test.dart`

**Interfaces:**
- Consumes: `PrivetService` (`send`, `runtimeConfig`, `setRuntimeConfig`), event stream.
- Produces:

```dart
class SendFileEntry { final String path; final String relativePath; final int size; final bool isDir; }
class SendPreparationState {
  final List<SendFileEntry> entries;
  final String? peerFingerprint, peerName;
  final bool sending;
  final String? error;
  bool get isReady; // entries.isNotEmpty && peerFingerprint != null && !sending
  int get totalSize;
}
final sendPreparationProvider = NotifierProvider<SendPreparationNotifier, SendPreparationState>(...);
class SendPreparationNotifier {
  void addFiles(List<String> paths);        // recursive scan, preserve relative paths
  void addFileEntry(SendFileEntry entry);
  void removeByRelativePath(String rel);
  void clearFiles();
  void setPeer(String fingerprint, {String? name});
  void clearPeer();
  Future<String?> send();                   // returns transfer id; watches first transfer event
}

final runtimeConfigProvider = FutureProvider<RuntimeConfigDto>((ref) async => service.runtimeConfig());
final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(...); // app-local prefs
class Settings { final String deviceName; final String? saveDir; final bool acceptAllTrusted; final String collisionPolicy; }
```

- [ ] **Step 1: Write the failing test**

`test/providers/send_preparation_test.dart` — file add/remove and `isReady` gating:

```dart
test('send preparation requires files and a peer', () {
  final n = SendPreparationNotifier();
  expect(n.state.isReady, isFalse);
  n.addFiles(['/tmp/a.txt']);
  expect(n.state.entries, hasLength(1));
  expect(n.state.isReady, isFalse); // no peer yet
  n.setPeer('fp', name: 'phone');
  expect(n.state.isReady, isTrue);
  n.removeByRelativePath('a.txt');
  expect(n.state.isReady, isFalse);
});
```

> `SendPreparationNotifier` here is constructed directly (not via a container) so the test only exercises pure state logic; the service calls in `send()` are covered by the widget/integration tasks.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/providers/send_preparation_test.dart`
Expected: FAIL — providers don't exist.

- [ ] **Step 3: Implement `send_preparation.dart`**

```dart
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ipc/events.dart';
import '../state/daemon_state.dart';

class SendFileEntry {
  SendFileEntry({required this.path, required this.relativePath, this.size = 0, this.isDir = false});
  final String path;
  final String relativePath;
  final int size;
  final bool isDir;
}

class SendPreparationState {
  const SendPreparationState({
    this.entries = const [],
    this.peerFingerprint,
    this.peerName,
    this.sending = false,
    this.error,
  });
  final List<SendFileEntry> entries;
  final String? peerFingerprint;
  final String? peerName;
  final bool sending;
  final String? error;
  bool get isReady => entries.isNotEmpty && peerFingerprint != null && !sending;
  int get totalSize => entries.fold(0, (sum, e) => sum + e.size);
}

final sendPreparationProvider = NotifierProvider<SendPreparationNotifier, SendPreparationState>(
    SendPreparationNotifier.new);

class SendPreparationNotifier extends Notifier<SendPreparationState> {
  @override
  SendPreparationState build() => const SendPreparationState();

  void addFileEntry(SendFileEntry entry) {
    state = SendPreparationState(
        entries: [...state.entries, entry], peerFingerprint: state.peerFingerprint,
        peerName: state.peerName, sending: state.sending, error: state.error);
  }

  void addFiles(List<String> paths) {
    final entries = <SendFileEntry>[];
    for (final p in paths) {
      final file = File(p);
      if (file.existsSync() && file.isFileSync) {
        entries.add(SendFileEntry(path: p, relativePath: file.uri.pathSegments.last, size: file.lengthSync()));
      } else if (Directory(p).existsSync()) {
        _scanDir(Directory(p), entries);
      }
    }
    state = SendPreparationState(
        entries: [...state.entries, ...entries], peerFingerprint: state.peerFingerprint,
        peerName: state.peerName, sending: state.sending, error: state.error);
  }

  void _scanDir(Directory dir, List<SendFileEntry> out, [String prefix = '']) {
    for (final entity in dir.listSync(followLinks: false)) {
      final rel = prefix.isEmpty ? entity.uri.pathSegments.last : '$prefix/${entity.uri.pathSegments.last}';
      if (entity is File) {
        out.add(SendFileEntry(path: entity.path, relativePath: rel, size: entity.lengthSync()));
      } else if (entity is Directory) {
        out.add(SendFileEntry(path: entity.path, relativePath: rel, isDir: true));
        _scanDir(entity, out, rel);
      }
    }
  }

  void removeByRelativePath(String relativePath) {
    state = SendPreparationState(
        entries: state.entries.where((e) => e.relativePath != relativePath).toList(),
        peerFingerprint: state.peerFingerprint, peerName: state.peerName,
        sending: state.sending, error: state.error);
  }

  void clearFiles() {
    state = SendPreparationState(peerFingerprint: state.peerFingerprint, peerName: state.peerName);
  }

  void setPeer(String fingerprint, {String? name}) {
    state = SendPreparationState(entries: state.entries, peerFingerprint: fingerprint,
        peerName: name, sending: state.sending, error: state.error);
  }

  void clearPeer() {
    state = SendPreparationState(entries: state.entries, sending: state.sending, error: state.error);
  }

  void setSending(bool sending) {
    state = SendPreparationState(entries: state.entries, peerFingerprint: state.peerFingerprint,
        peerName: state.peerName, sending: sending, error: state.error);
  }

  Future<String?> send() async {
    final service = ref.read(daemonStateProvider).service;
    final fp = state.peerFingerprint;
    if (service == null || fp == null || state.entries.isEmpty) return null;
    setSending(true);
    try {
      final paths = state.entries.map((e) => e.path).toList();
      final transferId = await service.send(paths, fp);
      // The daemon queues and prepares asynchronously; success surfaces via events.
      // The page watches activeTransfersProvider / service.events for this id.
      return transferId;
    } catch (e) {
      state = SendPreparationState(entries: state.entries, peerFingerprint: state.peerFingerprint,
          peerName: state.peerName, sending: false, error: e.toString());
      return null;
    }
  }
}
```

- [ ] **Step 4: Implement `settings.dart`**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ipc/dto.dart';
import '../state/daemon_state.dart';

class Settings {
  const Settings({
    this.deviceName = 'privet-device',
    this.saveDir,
    this.acceptAllTrusted = false,
    this.collisionPolicy = 'rename',
    this.leaveDaemonRunning = false,
  });
  final String deviceName;
  final String? saveDir;
  final bool acceptAllTrusted;
  final String collisionPolicy;
  final bool leaveDaemonRunning;
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<Settings> {
  @override
  Settings build() {
    // load SharedPreferences + current runtime config when the daemon is up
    return const Settings();
  }

  Future<void> loadFromDaemon(RuntimeConfigDto config) async {
    state = Settings(
      saveDir: config.saveDir,
      acceptAllTrusted: config.acceptAllTrusted,
      collisionPolicy: config.collisionPolicy,
      leaveDaemonRunning: state.leaveDaemonRunning,
    );
  }

  Future<void> setSaveDir(String dir) async {
    await ref.read(daemonStateProvider).service?.setRuntimeConfig(saveDir: dir);
    state = Settings(saveDir: dir, acceptAllTrusted: state.acceptAllTrusted,
        collisionPolicy: state.collisionPolicy, leaveDaemonRunning: state.leaveDaemonRunning);
  }

  Future<void> setAcceptAllTrusted(bool value) async {
    await ref.read(daemonStateProvider).service?.setRuntimeConfig(acceptAllTrusted: value);
    state = Settings(saveDir: state.saveDir, acceptAllTrusted: value,
        collisionPolicy: state.collisionPolicy, leaveDaemonRunning: state.leaveDaemonRunning);
  }

  Future<void> setCollisionPolicy(String value) async {
    await ref.read(daemonStateProvider).service?.setRuntimeConfig(collisionPolicy: value);
    state = Settings(saveDir: state.saveDir, acceptAllTrusted: state.acceptAllTrusted,
        collisionPolicy: value, leaveDaemonRunning: state.leaveDaemonRunning);
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/providers/send_preparation_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/providers/send_preparation.dart lib/providers/settings.dart test/providers/send_preparation_test.dart
git commit -m "feat(ui): send preparation and settings providers"
```

---
---

### Task 6: Shell + Home pages

**Files:**
- Create: `lib/pages/shell_page.dart`
- Create: `lib/pages/home_page.dart`
- Port from: `D:\C-Codes\privet-old\privet_app\lib\pages\shell_page.dart`, `home_page.dart`

**Interfaces:**
- Consumes: providers from Tasks 2–5, widgets from Task 7.

**Porting spec (read the old files first):**
- `ShellPage`: keep the `NavigationBar` + `IndexedStack` of Home/History/Settings. Replace the old `pendingShare`/`urlPairing` listeners with the new deeplink handling (Task 10).
- `HomePage`: keep the sectioned `ListView` and order: identity card → pairing banners → awaiting-accept tiles → active transfers → recent → known devices → nearby devices. **Deltas:**
  - The identity card's QR (Task 10) encodes `{hosts, fingerprint, code, name}`.
  - "Known Devices" = `trustedListProvider` (was `knownDevicesProvider` from FFI).
  - "Nearby Devices" = `peerListProvider`.
  - The per-device auto-accept star button on transfer tiles is **removed**.
  - Pull-to-refresh calls `peerListProvider.refresh()` + `trustedListProvider.refresh()`.
  - The FAB still opens SendPreparationPage, but `_navigateToSend` now passes a **fingerprint** (from the tapped peer/device), not an address.

- [ ] **Step 1: Port `ShellPage`**

Copy the old `shell_page.dart`, strip the FFI-isms, and wire the new tab providers:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'home_page.dart';
import 'history_page.dart';
import 'settings_page.dart';

final shellTabProvider = NotifierProvider<ShellTabNotifier, int>(ShellTabNotifier.new);

class ShellTabNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void select(int index) => state = index;
}

class ShellPage extends ConsumerWidget {
  const ShellPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(shellTabProvider);
    return Scaffold(
      body: IndexedStack(index: index, children: const [HomePage(), HistoryPage(), SettingsPage()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => ref.read(shellTabProvider.notifier).select(i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.history_outlined), selectedIcon: Icon(Icons.history), label: 'History'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Port `HomePage`**

Copy the old `home_page.dart`. Replace the engine/data sources per the porting spec above. The identity card section:

```dart
final identityAsync = ref.watch(identityProvider);
final peers = ref.watch(peerListProvider);
final trusted = ref.watch(trustedListProvider);
final transfers = ref.watch(activeTransfersProvider);
final pairings = ref.watch(pairingProvider);
```

Render the same visual sections from these. The QR widget and pairing code are Task 10; until then show the fingerprint text and a placeholder for the QR.

- [ ] **Step 3: Verify it builds and renders**

Run: `flutter analyze`
Expected: clean. (A live-daemon smoke of HomePage is Task 12; until then a golden-free build check suffices.)

- [ ] **Step 4: Commit**

```bash
git add lib/pages/shell_page.dart lib/pages/home_page.dart
git commit -m "feat(ui): shell and home pages over daemon providers"
```

---
---

### Task 7: Port shared widgets

**Files:**
- Create: `lib/widgets/transfer_tile.dart`, `lib/widgets/pairing_banner.dart`, `lib/widgets/peer_picker_sheet.dart`, `lib/widgets/file_tree_view.dart`
- Port from: `D:\C-Codes\privet-old\privet_app\lib\widgets\*.dart`

**Porting spec (read the old files first):**
- `file_tree_view.dart`: port unchanged (it already takes `FileTreeNode` + `onRemoveFile`/`onOpenFile`/`formatSize`). The `FileTreeNode` builders move to `lib/models/file_tree.dart` (Task 8).
- `transfer_tile.dart`: keep the state-driven card, but:
  - `TransferState` now comes from the daemon model (Task 3).
  - Remove the **Always-accept star** action (no per-device auto-accept).
  - The awaiting-accept tile shows **Reject** / **Accept** → `activeTransfersProvider.reject(id)` / `.accept(id)`.
  - The completed tile's countdown stays.
- `pairing_banner.dart`: keep the orange card; actions call `pairingProvider.trust/trustAndAccept/reject` (mapped to the pairing flow in Task 9).
- `peer_picker_sheet.dart`: keep the bottom sheet, but "Nearby" items pass a **fingerprint** (from `PeerDto`), and "Send by Address" becomes **pair-by-address** (Task 9).

- [ ] **Step 1: Port the four widgets**

Copy each old widget, apply the deltas above. No new test logic here (visual); ensure `flutter analyze` is clean.

- [ ] **Step 2: Verify**

Run: `flutter analyze`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/widgets/transfer_tile.dart lib/widgets/pairing_banner.dart lib/widgets/peer_picker_sheet.dart lib/widgets/file_tree_view.dart
git commit -m "feat(ui): port shared widgets to daemon state"
```

---
---

### Task 8: History page

**Files:**
- Create: `lib/pages/history_page.dart`
- Create: `lib/models/file_tree.dart` (ported builders)
- Port from: `D:\C-Codes\privet-old\privet_app\lib\pages\history_page.dart`

**Porting spec (read the old file first):**
- Keep the `ExpansionTile` list from `transferHistoryProvider`.
- **File list per record:** the old page built `buildFileTreeFromRecords(files)` from per-file paths. The daemon exposes detail via `get_history_detail`. On expand, call `historyProvider.detail(transferId)` and render a `FileTreeView` from `HistoryDetailDto.files` using `relativePath` → size (`buildFileTreeFromSizedPaths`).
- **Open file:** each leaf's `absolutePath` (may be null for pre-v2 send records → show "File not accessible"). On tap → `OpenFile.open(path)`.
- **Resend / Forward:**
  - Resend to the same peer → `historyProvider.resend(transferId)` (daemon re-runs stored intent).
  - Forward to a different peer → build `SendFileEntry` list from detail `absolutePath`s, push `SendPreparationPage` prefilled (no peer).
- **Delete** → `historyProvider.delete(transferId)` (with the same confirm dialog).
- Error text from `HistoryEntryDto` is not exposed by the daemon (status only); drop the old per-record error line.

- [ ] **Step 1: Port the page**

Copy the old `history_page.dart` and apply the deltas. Implement the detail-loading ExpansionTile:

```dart
Future<HistoryDetailDto> _loadDetail(BuildContext context, String id) =>
    context.read(transferHistoryProvider.notifier).detail(id);
```

Render files from `detail.files` via the ported `FileTreeView`.

- [ ] **Step 2: Verify**

Run: `flutter analyze`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/pages/history_page.dart lib/models/file_tree.dart
git commit -m "feat(ui): history page with daemon detail/delete/resend"
```

---
---

### Task 9: Send-preparation page + pairing flow

**Files:**
- Create: `lib/pages/send_preparation_page.dart`
- Port from: `D:\C-Codes\privet-old\privet_app\lib\pages\send_preparation_page.dart`

**Porting spec (read the old file first):**
- Keep the compose layout: recipient section → pairing card → file list (tree mode) → add buttons → bottom send bar.
- **Recipient section** now shows `peerName ?? 'No recipient selected'`; "Change" opens `PeerPickerSheet` which returns a **fingerprint** → `sendPreparationProvider.setPeer(fp, name: ...)`.
- **Add files/folder/paste/create-text:** port `_pickFiles`, `_pickFolder`, `_pasteFromClipboard`, `_createTextFile` from the old page, feeding `sendPreparationProvider.addFiles/addFileEntry`. The clipboard service is Task 11.
- **Pairing card:** shown when the recipient's fingerprint is not in `trustedListProvider`. Two-sided flow:
  1. **Display-my-code:** `service.generatePairingCode()` → show the 6-digit code; tell the user the other device enters it.
  2. **Enter-their-code:** a dialog where the user types a code from the other device → `service.pair(fingerprint: fp, code: ...)`.
  On success (fingerprint now trusted), refresh `trustedListProvider` and proceed.
- **Send:** `sendPreparationProvider.send()` returns a transfer id; then watch `activeTransfersProvider` for that id → on `completed`/`failed`/`cancelled`, pop the page. Replace the old 60s polling loop with the event-driven wait:

```dart
Future<void> _sendAndWait(WidgetRef ref, BuildContext context) async {
  final notifier = ref.read(sendPreparationProvider.notifier);
  final id = await notifier.send();
  if (id == null) return; // error already surfaced in state
  // subscribe once for this transfer id
  late final StreamSubscription<PrivetEvent> sub;
  sub = ref.read(daemonStateProvider).service!.events.listen((event) {
    if (event is TransferCompletedEvent && event.transferId == id) {
      sub.cancel();
      Navigator.of(context).popUntil((r) => r.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transfer complete')));
    } else if (event is TransferFailedEvent && event.transferId == id) {
      sub.cancel();
      notifier.setSending(false);
    } else if (event is TransferCancelledEvent && event.transferId == id) {
      sub.cancel();
      notifier.setSending(false);
    }
  });
}
```

- [ ] **Step 1: Port the page**

Copy the old page and apply the deltas above. The pair-by-address flow (from `PeerPickerSheet`'s "Send by Address") reuses the enter-their-code dialog with `service.pair(ip:..., quicPort:..., tcpPort:..., code: ...)`.

- [ ] **Step 2: Verify**

Run: `flutter analyze`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/pages/send_preparation_page.dart
git commit -m "feat(ui): send preparation page with event-driven send and pairing flow"
```

---
---

### Task 10: QR pairing + deeplink

**Files:**
- Create: `lib/services/pairing_url.dart`
- Create: `lib/services/deeplink_service.dart`
- Port from: `D:\C-Codes\privet-old\privet_app\lib\services\deeplink_service.dart`, `lib\utils\pairing_url.dart`

**Porting spec (read the old files first):**
- `pairing_url.dart`: the QR URL gains the pairing **code**:
  - `PairingUrl.build({fingerprint, deviceName, networks, port, code})` → `privet://pair?h=IP:PORT&fp=FINGERPRINT&n=NAME&code=123456`.
  - `PairingUrl.parse(String)` must accept the `code` param (optional) and return it.
- **QR flow (Home identity card):**
  1. On QR expand, call `service.generatePairingCode()`.
  2. Render `QrImageView` encoding `PairingUrl.build(..., code)`.
  3. The scanning device opens the URL → `DeeplinkService` → verify fingerprint matches a discovered/trusted peer → `service.pair(fingerprint: <from URL or discovered>, code: <from URL>)`.
- **Deeplink:** use `app_links`. In `main.dart`/`ShellPage`, subscribe to `uriLinksStream`, parse via `PairingUrl.parse`, and run the pair flow. Add the `privet://` scheme:
  - Android: `AndroidManifest.xml` intent-filter (Plan 4 wires the manifest).
  - Windows: `app_links` registers the custom protocol handler at build time.

- [ ] **Step 1: Port `pairing_url.dart`**

Copy the old file, add the `code` parameter to build/parse, add unit tests in `test/services/pairing_url_test.dart` (build → parse round-trip with code).

- [ ] **Step 2: Port `deeplink_service.dart`**

Copy the old file, replace the MethodChannel with `app_links`. Emit `ParsedPairingUrl` on a broadcast stream.

- [ ] **Step 3: Wire the QR card on Home**

Add `generate_pairing_code` to the identity card: on expand, `final code = await service.generatePairingCode();` then render the QR with the code and a "Scan with the Privet app to pair" caption (port the old `_PairingQrCode` widget).

- [ ] **Step 4: Verify**

Run: `flutter analyze && flutter test test/services/pairing_url_test.dart`
Expected: clean; URL tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/services/pairing_url.dart lib/services/deeplink_service.dart test/services/pairing_url_test.dart
git commit -m "feat(ui): QR pairing with code and deeplink"
```

---
---

### Task 11: Clipboard service

**Files:**
- Create: `lib/services/clipboard_service.dart`
- Port from: `D:\C-Codes\privet-old\privet_app\lib\services\clipboard_service.dart`

**Porting spec (read the old file first):**
- Keep `readFilePaths()` (Windows CF_HDROP / Linux `text/uri-list`) — the paste-from-file-manager flow. On Windows, prefer the `win32` package's clipboard APIs over the old raw `dart:ffi` (the `win32` dependency already exists from Plan 2).
- Keep `saveToFile`/`textFilename`/`uniqueFile` (create-text and clipboard-text-to-file) — these write real paths the daemon can read.
- Drop the image-specific decode on Android (desktop-only app in this plan); keep the Windows image path only if trivial, else defer to Plan 4.

- [ ] **Step 1: Port the service**

Copy the old file, swap the Windows clipboard internals to `win32`, drop the Android MethodChannel branches (Plan 4 restores what's needed).

- [ ] **Step 2: Verify**

Run: `flutter analyze`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/services/clipboard_service.dart
git commit -m "feat(ui): clipboard file-path and text-to-file service"
```

---
---

### Task 12: End-to-end UI smoke against a real daemon

**Files:**
- Create: `test/integration/app_smoke_test.dart`
- Requires: `privetd` built (Plan 1) and the Plan 2 smoke infrastructure.

- [ ] **Step 1: Run the app against a live daemon**

Using the `privetd` binary from Plan 1, start the daemon, launch the Flutter app (Windows), and manually verify:
1. Home shows the identity card, a scan of nearby devices, and the QR with a code.
2. Sending a file to a paired device shows the transfer tile progress → completed.
3. Receiving an offer shows the awaiting-accept tile → Accept lands the file in `save_dir`.
4. History lists the transfer; expanding shows files; Open file works; Delete removes it.
5. Settings: changing `save_dir`/`accept_all_trusted` applies live; restart-required fields are visibly documented.

- [ ] **Step 2: Automated smoke (optional but encouraged)**

Port the Plan 2 `privetd_smoke_test` into an app-level test that boots the provider tree and asserts `daemonStateProvider` reaches `running` and `peerListProvider` reflects a scripted `device_discovered`.

- [ ] **Step 3: Commit any fixes surfaced**

If the smoke finds bugs, fix them in the owning task's file and commit with a descriptive message. Report the manual checklist results in the plan's execution notes.
