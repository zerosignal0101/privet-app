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

  @override
  Map<String, ActiveTransfer> build() {
    final service = ref.watch(daemonStateProvider).service;
    if (service != null) {
      _sub = service.events.listen(applyEvent);
    }
    ref.onDispose(() => _sub?.cancel());
    return const {};
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

  Future<void> accept(String id) async {
    await ref.read(daemonStateProvider).service?.acceptTransfer(id, accept: true);
    final cur = state[id];
    if (cur != null) state = {...state, id: _withState(cur, TransferState.transferring)};
  }

  Future<void> reject(String id) async =>
      ref.read(daemonStateProvider).service?.acceptTransfer(id, accept: false);

  Future<void> cancel(String id) async =>
      ref.read(daemonStateProvider).service?.cancelTransfer(id);

  Future<void> pause(String id) async =>
      ref.read(daemonStateProvider).service?.pauseTransfer(id);

  Future<void> resume(String id) async =>
      ref.read(daemonStateProvider).service?.continueTransfer(id);
}
