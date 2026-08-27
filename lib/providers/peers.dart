import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ipc/dto.dart';
import '../services/ipc/events.dart';
import '../state/daemon_state.dart';

/// The daemon's own device identity (fingerprint + name).
final identityProvider = FutureProvider<IdentityDto?>((ref) async {
  return ref.watch(daemonStateProvider).service?.identity();
});

/// Discovered nearby peers, reconciled from `list_peers` snapshots and
/// `device_discovered` / `device_lost` events.
final peerListProvider =
    NotifierProvider<PeerListNotifier, List<PeerDto>>(PeerListNotifier.new);

class PeerListNotifier extends Notifier<List<PeerDto>> {
  StreamSubscription<PrivetEvent>? _sub;

  @override
  List<PeerDto> build() {
    final service = ref.watch(daemonStateProvider).service;
    if (service != null) {
      _sub = service.events.listen(_onEvent);
    }
    ref.onDispose(() => _sub?.cancel());
    return const [];
  }

  Future<void> refresh() async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) return;
    state = await service.peers();
  }

  void _onEvent(PrivetEvent event) {
    switch (event) {
      case DeviceDiscoveredEvent(:final deviceFingerprint, :final deviceName):
        final existing =
            state.indexWhere((p) => p.deviceFingerprint == deviceFingerprint);
        if (existing >= 0) {
          final peers = [...state];
          final cur = peers[existing];
          peers[existing] = PeerDto(
            deviceFingerprint: deviceFingerprint,
            deviceName: deviceName,
            state: cur.state,
            lastBeaconMs: cur.lastBeaconMs,
            candidates: cur.candidates,
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
        state =
            state.where((p) => p.deviceFingerprint != deviceFingerprint).toList();
      default:
        break;
    }
  }
}

/// Pairing-completed peers (the daemon's trusted list).
final trustedListProvider = FutureProvider<List<TrustedPeerDto>>((ref) async {
  final service = ref.watch(daemonStateProvider).service;
  return service?.trusted() ?? const [];
});
