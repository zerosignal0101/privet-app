import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ipc/events.dart';
import '../state/daemon_state.dart';
import 'peers.dart';

/// A peer that requested pairing and is waiting for the user to complete the
/// code exchange.
class PairRequest {
  PairRequest(this.deviceFingerprint);
  final String deviceFingerprint;
}

final pairingProvider =
    NotifierProvider<PairingNotifier, List<PairRequest>>(PairingNotifier.new);

class PairingNotifier extends Notifier<List<PairRequest>> {
  StreamSubscription<PrivetEvent>? _sub;

  @override
  List<PairRequest> build() {
    final service = ref.watch(daemonStateProvider).service;
    if (service != null) {
      _sub = service.events.listen(applyEvent);
    }
    ref.onDispose(() => _sub?.cancel());
    return const [];
  }

  void applyEvent(PrivetEvent event) {
    switch (event) {
      case PairingRequestedEvent(:final deviceFingerprint):
        if (!state.any((p) => p.deviceFingerprint == deviceFingerprint)) {
          state = [...state, PairRequest(deviceFingerprint)];
        }
        break;
      case PairingResultEvent(:final deviceFingerprint, :final success):
        state = state
            .where((p) => p.deviceFingerprint != deviceFingerprint)
            .toList();
        // A successful pairing commits the peer to the daemon's trust store.
        // The responder (e.g. a desktop accepting a scanned QR) only learns a
        // pairing completed through this event, so refresh the trusted lists
        // here — otherwise Trusted Devices / Known Devices stay stale until a
        // daemon restart.
        if (success) {
          ref.invalidate(trustedListProvider);
          ref.invalidate(allTrustedListProvider);
        }
        break;
      default:
        break;
    }
  }

  /// Drop a pending request (after the user acted on it). The daemon also
  /// emits a `pairing_result` event that clears it, but the send flow clears
  /// optimistically so the banner dismisses immediately.
  void resolve(String deviceFingerprint) {
    state = state
        .where((p) => p.deviceFingerprint != deviceFingerprint)
        .toList();
  }
}
