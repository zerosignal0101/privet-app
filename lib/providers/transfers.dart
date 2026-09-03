import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ipc/events.dart';
import '../services/privet_service.dart';
import '../state/daemon_state.dart';
import 'send_preparation.dart';

enum TransferState {
  preparing,
  offered,
  transferring,
  reconnecting,
  paused,
  completed,
  failed,
  cancelled,
}

/// A live transfer as surfaced by `transfer_*` events. Keyed by `transferId`
/// in [activeTransfersProvider]; terminal states are kept until the next
/// snapshot refresh clears them.
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
  final String direction; // 'send' | 'receive'
  final TransferState state;
  final int fileCount;
  final int totalBytes;
  final int verifiedBytes;
  final String? peerName;
  final String? errorCode;
  final bool retryable;

  /// An incoming offer that the user has not yet accepted.
  final bool isAwaitingAccept;

  double get fraction => totalBytes == 0 ? 0 : verifiedBytes / totalBytes;

  String? get fileCountText =>
      fileCount > 0 ? '$fileCount ${fileCount == 1 ? 'file' : 'files'}' : null;
}

final activeTransfersProvider =
    NotifierProvider<ActiveTransfersNotifier, Map<String, ActiveTransfer>>(
        ActiveTransfersNotifier.new);

class ActiveTransfersNotifier extends Notifier<Map<String, ActiveTransfer>> {
  StreamSubscription<PrivetEvent>? _sub;
  Timer? _reconcileTimer;
  final Map<String, DateTime> _suspectSince = {};
  final Map<String, DateTime> _lastEvent = {};

  /// A transferring/reconnecting tile that has received NO event for this long
  /// is presumed stale. The daemon's progress tick is ~1s, so total silence far
  /// beyond that means the transfer's events stopped reaching the GUI (dead IPC
  /// connection, dropped terminal event) — the tile must not pin 0% forever.
  /// Only the *state* counts here: the daemon's active_transfers check handles
  /// the healthy-but-not-yet-unregistered case.
  static final Duration stuckTimeout = const Duration(seconds: 45);

  /// Time source for the silence self-heal. Injectable so tests can pin the
  /// clock (fake-async pumping does not advance `DateTime.now()`).
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  bool _reconciling = false;

  /// Whether the daemon is in "Accept All Trusted" mode. When on, incoming
  /// offers are auto-accepted by the daemon, so the GUI must not show a confirm
  /// prompt for them. Cached from the daemon's runtime config (and refreshed on
  /// `runtime_config_changed`).
  bool _autoAccept = false;

  @override
  Map<String, ActiveTransfer> build() {
    // The daemon may restart (a new service replaces the old); drop any stale
    // subscription before re-subscribing.
    _sub?.cancel();
    final service = ref.watch(daemonStateProvider).service;
    if (service != null) {
      _sub = service.events.listen(applyEvent);
      _loadAutoAccept(service);
    }
    // Safety net: reconcile against the daemon's active_transfers so a tile can
    // never linger forever when a terminal event was missed (disconnect,
    // receiver error, etc.). Grace is two observations to avoid pruning a
    // transfer that is still registering on the daemon.
    _reconcileTimer = Timer.periodic(
        const Duration(seconds: 10), (_) => _reconcileActive());
    ref.onDispose(() {
      _sub?.cancel();
      _reconcileTimer?.cancel();
    });
    return const {};
  }

  /// Reads the daemon's current runtime config so [_autoAccept] is known before
  /// the first offer arrives. The daemon auto-accepts every offer while
  /// `accept_all_trusted` is set, so incoming offers must not show a confirm.
  Future<void> _loadAutoAccept(PrivetService service) async {
    try {
      final config = await service.runtimeConfig();
      _autoAccept = config.acceptAllTrusted;
    } catch (_) {
      // Daemon unreachable — keep the last known value (false by default).
    }
  }

  /// Drops non-terminal transfers the daemon no longer reports as active.
  Future<void> _reconcileActive() async {
    if (_reconciling) return;
    _reconciling = true;
    final now = clock();
    try {
      final service = ref.read(daemonStateProvider).service;
      if (service == null) {
        // No daemon at all — nothing to reconcile against; rely on the silence
        // self-heal so a stale tile can still not linger forever.
        _reconcileStuck(now);
        return;
      }
      final active = (await service.status()).activeTransfers.toSet();
      final stale = <String>[];
      for (final entry in state.entries) {
        final t = entry.value;
        // Terminal tiles are cleaned by their 5s countdown, not here.
        if (t.state == TransferState.completed ||
            t.state == TransferState.failed ||
            t.state == TransferState.cancelled) {
          _suspectSince.remove(t.transferId);
          continue;
        }
        if (active.contains(t.transferId)) {
          _suspectSince.remove(t.transferId);
          continue;
        }
        final first = _suspectSince[t.transferId];
        if (first == null) {
          _suspectSince[t.transferId] = now;
        } else if (now.difference(first) >= const Duration(seconds: 20)) {
          stale.add(t.transferId);
        }
      }
      // A send the daemon no longer tracks but whose terminal event we never
      // saw is done: free its cached staging files so they don't leak.
      for (final id in stale) {
        _releaseSendTemp(id);
      }
      _remove(stale);
    } catch (_) {
      // Daemon unreachable (dead client, socket closed, …). We can't ask whether
      // the transfer is still active, so fall back to the time-based self-heal:
      // a tile that has received no event at all for `stuckTimeout` is stale and
      // must not pin a 0% tile forever. Without this, a missed terminal event on
      // a dead IPC connection left the tile on screen indefinitely.
      _reconcileStuck(now);
    } finally {
      _reconciling = false;
    }
  }

  /// Removes transferring/reconnecting tiles that have had no event for
  /// [stuckTimeout]. Runs even when the daemon is unreachable. A healthy
  /// transfer emits progress at least every second, so total silence far beyond
  /// that is not a slow transfer — it is a transfer whose events stopped
  /// reaching the GUI. Paused/awaiting-accept/preparing tiles are exempt:
  /// silence there is legitimate (waiting for the user or the peer).
  void _reconcileStuck(DateTime now) {
    final stale = <String>[];
    for (final entry in state.entries) {
      final t = entry.value;
      if (t.state != TransferState.transferring &&
          t.state != TransferState.reconnecting) {
        continue;
      }
      final last = _lastEvent[t.transferId];
      if (last != null && now.difference(last) >= stuckTimeout) {
        stale.add(t.transferId);
      }
    }
    _remove(stale);
  }

  void _remove(List<String> stale) {
    if (stale.isEmpty) return;
    final next = Map<String, ActiveTransfer>.from(state);
    for (final id in stale) {
      next.remove(id);
      _suspectSince.remove(id);
      _lastEvent.remove(id);
    }
    state = next;
  }

  void applyEvent(PrivetEvent event) {
    _touch(event);
    switch (event) {
      case TransferPreparingEvent(:final transferId):
        state = {
          ...state,
          transferId: _base(transferId, 'send', TransferState.preparing),
        };
        break;
      case TransferOfferedEvent(
          :final transferId, :final fileCount, :final totalBytes):
        final cur = state[transferId];
        if (cur != null && cur.direction == 'send') {
          // The sender daemon echoes `transfer_offered` once it has sent its
          // offer to the remote receiver. That is the transfer we already track
          // as a send (created by `transfer_preparing`), NOT an incoming offer —
          // the *remote* side decides whether to accept. Keep the send direction
          // and don't mark it awaiting-accept, or the tile would show a bogus
          // "Accept transfer?" on the sending device.
          state = {
            ...state,
            transferId: ActiveTransfer(
                transferId: transferId,
                direction: 'send',
                state: TransferState.preparing,
                fileCount: fileCount,
                totalBytes: totalBytes,
                verifiedBytes: cur.verifiedBytes,
                peerName: cur.peerName),
          };
        } else if (_autoAccept) {
          // Incoming offer that the daemon will accept automatically ("Accept
          // All Trusted"). Surface it as a receive in progress — no confirm
          // prompt, or the tile would briefly show "Accept transfer?" before
          // the daemon's auto-accept turns it into a progress bar.
          state = {
            ...state,
            transferId: ActiveTransfer(
                transferId: transferId,
                direction: 'receive',
                state: TransferState.transferring,
                fileCount: fileCount,
                totalBytes: totalBytes),
          };
        } else {
          // Incoming offer from a remote sender — surface accept/reject.
          state = {
            ...state,
            transferId: ActiveTransfer(
                transferId: transferId,
                direction: 'receive',
                state: TransferState.offered,
                fileCount: fileCount,
                totalBytes: totalBytes,
                isAwaitingAccept: true),
          };
        }
        break;
      case TransferProgressEvent(
          :final transferId, :final verifiedBytes, :final totalBytes):
        final cur = state[transferId];
        if (cur == null) break;
        state = {
          ...state,
          transferId: ActiveTransfer(
              transferId: transferId,
              direction: cur.direction,
              state: TransferState.transferring,
              fileCount: cur.fileCount,
              totalBytes: totalBytes,
              verifiedBytes: verifiedBytes,
              peerName: cur.peerName),
        };
        break;
      case TransferReconnectingEvent(:final transferId):
        final cur = state[transferId];
        if (cur == null) break;
        state = {
          ...state,
          transferId: _withState(cur, TransferState.reconnecting),
        };
        break;
      case TransferPausedEvent(:final transferId):
        final cur = state[transferId];
        if (cur == null) break;
        state = {
          ...state,
          transferId: _withState(cur, TransferState.paused),
        };
        break;
      case TransferResumedEvent(:final transferId):
        final cur = state[transferId];
        if (cur == null) break;
        state = {
          ...state,
          transferId: _withState(cur, TransferState.transferring),
        };
        break;
      case TransferCompletedEvent(:final transferId):
        state = {
          ...state,
          transferId: _terminal(transferId, TransferState.completed),
        };
        _releaseSendTemp(transferId);
        break;
      case TransferCancelledEvent(:final transferId):
        state = {
          ...state,
          transferId: _terminal(transferId, TransferState.cancelled),
        };
        _releaseSendTemp(transferId);
        break;
      case TransferFailedEvent(:final transferId, :final errorCode, :final retryable):
        state = {
          ...state,
          transferId: _failed(transferId, errorCode, retryable),
        };
        _releaseSendTemp(transferId);
        break;
      case RuntimeConfigChangedEvent(:final config):
        // "Accept All Trusted" toggling must affect how later offers are
        // presented (confirm prompt vs. straight-to-progress).
        _autoAccept = config.acceptAllTrusted;
        break;
      default:
        break;
    }
  }

  /// Frees the Android staging copies (if any) tracked for a send once it is
  /// terminal or the daemon stops reporting it. The send-preparation notifier
  /// registered them at `send` time keyed by transfer id; releasing is
  /// idempotent and a no-op for receives and desktop paths.
  void _releaseSendTemp(String transferId) {
    unawaited(
        ref.read(sendPreparationProvider.notifier).releaseTempFor(transferId));
  }

  /// Records the moment this transfer last produced an event, so the silence
  /// self-heal can tell "still flowing" from "events stopped arriving".
  void _touch(PrivetEvent event) {
    final String? id = switch (event) {
      TransferPreparingEvent(:final transferId) ||
      TransferPreparingProgressEvent(:final transferId) ||
      TransferOfferedEvent(:final transferId) ||
      TransferProgressEvent(:final transferId) ||
      TransferReconnectingEvent(:final transferId) ||
      TransferResumedEvent(:final transferId) ||
      TransferPausedEvent(:final transferId) ||
      TransferCompletedEvent(:final transferId) ||
      TransferCancelledEvent(:final transferId) ||
      TransferFailedEvent(:final transferId) =>
        transferId,
      _ => null,
    };
    if (id != null) _lastEvent[id] = DateTime.now();
  }

  /// Copy an existing transfer with a new state (keeps counts + peer name).
  ActiveTransfer _withState(ActiveTransfer cur, TransferState st) =>
      ActiveTransfer(
        transferId: cur.transferId,
        direction: cur.direction,
        state: st,
        fileCount: cur.fileCount,
        totalBytes: cur.totalBytes,
        verifiedBytes: cur.verifiedBytes,
        peerName: cur.peerName,
      );

  ActiveTransfer _base(String id, String direction, TransferState st) =>
      ActiveTransfer(transferId: id, direction: direction, state: st);

  ActiveTransfer _terminal(String id, TransferState st) {
    final cur = state[id];
    return ActiveTransfer(
        transferId: id,
        direction: cur?.direction ?? 'send',
        state: st,
        fileCount: cur?.fileCount ?? 0,
        totalBytes: cur?.totalBytes ?? 0,
        verifiedBytes: cur?.verifiedBytes ?? 0,
        peerName: cur?.peerName);
  }

  ActiveTransfer _failed(String id, String errorCode, bool retryable) {
    final cur = state[id];
    return ActiveTransfer(
        transferId: id,
        direction: cur?.direction ?? 'send',
        state: TransferState.failed,
        fileCount: cur?.fileCount ?? 0,
        totalBytes: cur?.totalBytes ?? 0,
        verifiedBytes: cur?.verifiedBytes ?? 0,
        peerName: cur?.peerName,
        errorCode: errorCode,
        retryable: retryable);
  }

  /// Drop a transfer from the live map (e.g. a terminal tile's countdown
  /// expired). The daemon keeps authoritative history via the history provider.
  void remove(String transferId) {
    state = Map<String, ActiveTransfer>.from(state)..remove(transferId);
    _suspectSince.remove(transferId);
    _lastEvent.remove(transferId);
  }

  /// Accepts an incoming offer. Returns null on success, or a message the UI
  /// can show when the decision could not be delivered (e.g. the offer already
  /// timed out). On failure the transfer is left as-is — the daemon's offer
  /// timeout emits a terminal event that cleans the tile up.
  Future<String?> accept(String id) async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) return 'daemon not running';
    try {
      await service.acceptTransfer(id, accept: true);
    } catch (e) {
      return _friendlyError(e);
    }
    final cur = state[id];
    if (cur != null && cur.isAwaitingAccept) {
      state = {...state, id: _withState(cur, TransferState.transferring)};
    }
    return null;
  }

  /// Rejects an incoming offer. Returns null on success, or a message when the
  /// decision could not be delivered.
  Future<String?> reject(String id) async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) return 'daemon not running';
    try {
      await service.acceptTransfer(id, accept: false);
    } catch (e) {
      return _friendlyError(e);
    }
    return null;
  }

  /// Turns a daemon/IPC error into a short, user-facing message. The most
  /// common one — "transfer offer is not pending" — means the receiver's own
  /// decision window already elapsed.
  String _friendlyError(Object e) {
    final raw = e.toString();
    final detail =
        raw.contains(': ') ? raw.substring(raw.indexOf(': ') + 2) : raw;
    if (detail.contains('not pending')) {
      return 'Offer already expired — the transfer was cancelled.';
    }
    if (detail.trim().isEmpty) return 'Failed to reach the daemon';
    return detail.trim();
  }

  Future<void> cancel(String id) async {
    try {
      await ref.read(daemonStateProvider).service?.cancelTransfer(id);
    } catch (_) {
      // Terminal events arrive from the daemon anyway; keep the tile until then.
    }
  }

  Future<void> pause(String id) async {
    try {
      await ref.read(daemonStateProvider).service?.pauseTransfer(id);
    } catch (_) {}
  }

  Future<void> resume(String id) async {
    try {
      await ref.read(daemonStateProvider).service?.continueTransfer(id);
    } catch (_) {}
  }
}
