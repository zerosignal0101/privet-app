import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ipc/dto.dart';
import '../services/ipc/events.dart';
import '../state/daemon_state.dart';

final transferHistoryProvider =
    NotifierProvider<HistoryNotifier, List<HistoryEntryDto>>(HistoryNotifier.new);

class HistoryNotifier extends Notifier<List<HistoryEntryDto>> {
  StreamSubscription<PrivetEvent>? _sub;

  @override
  List<HistoryEntryDto> build() {
    final service = ref.watch(daemonStateProvider).service;
    if (service != null) {
      _sub = service.events.listen((event) {
        // Terminal transfer events flush history on the daemon side, so refresh
        // the list whenever one arrives.
        if (event is TransferCompletedEvent ||
            event is TransferFailedEvent ||
            event is TransferCancelledEvent) {
          refresh();
        }
      });
    }
    ref.onDispose(() => _sub?.cancel());
    // Load the current list once (and whenever the daemon comes up).
    Future.microtask(refresh);
    return const [];
  }

  Future<void> refresh() async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) return;
    try {
      state = await service.history(limit: 100);
    } catch (_) {
      // Daemon unreachable — keep the last known list.
    }
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
