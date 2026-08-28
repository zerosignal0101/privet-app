import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ipc/events.dart';
import '../state/daemon_state.dart';

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
  bool _reconciling = false;

  @override
  Map<String, ActiveTransfer> build() {
    final service = ref.watch(daemonStateProvider).service;
    if (service != null) {
      _sub = service.events.listen(applyEvent);
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

  /// Drops non-terminal transfers the daemon no longer reports as active.
  Future<void> _reconcileActive() async {
    if (_reconciling) return;
    _reconciling = true;
    try {
      final service = ref.read(daemonStateProvider).service;
      if (service == null) return;
      final active = (await service.status()).activeTransfers.toSet();
      final now = DateTime.now();
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
      if (stale.isNotEmpty) {
        final next = Map<String, ActiveTransfer>.from(state);
        for (final id in stale) {
          next.remove(id);
          _suspectSince.remove(id);
        }
        state = next;
      }
    } catch (_) {
      // Daemon unreachable — skip this cycle; the transfer stays until it
      // either terminates or a later reconcile succeeds.
    } finally {
      _reconciling = false;
    }
  }

  void applyEvent(PrivetEvent event) {
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
        break;
      case TransferCancelledEvent(:final transferId):
        state = {
          ...state,
          transferId: _terminal(transferId, TransferState.cancelled),
        };
        break;
      case TransferFailedEvent(:final transferId, :final errorCode, :final retryable):
        state = {
          ...state,
          transferId: _failed(transferId, errorCode, retryable),
        };
        break;
      default:
        break;
    }
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
