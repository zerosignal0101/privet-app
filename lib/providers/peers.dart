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

/// Fingerprints the daemon currently considers online (discovered and not
/// stale/lost). Drives the Online/Offline markers on Known Devices and gates
/// sends to a specific peer.
final onlinePeerFingerprintsProvider = Provider<Set<String>>((ref) {
  final peers = ref.watch(peerListProvider);
  return {for (final p in peers) if (p.isOnline) p.deviceFingerprint};
});

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

  /// Best-effort self fingerprint from the cached daemon status. Null until the
  /// status has been fetched; the UI also filters at render time with the
  /// resolved identity, so this provider-level filter is defense in depth.
  String? get _selfFingerprint =>
      ref.read(daemonStatusProvider).value?.deviceFingerprint;

  Future<void> refresh() async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) return;
    final self = _selfFingerprint;
    // Drop peers the daemon has already declared gone (lost / goodbye). The
    // discovery engine keeps those records in its store until they re-beacon,
    // so without this filter a manual refresh would resurrect a device that
    // `device_lost` just removed from the list.
    final peers = (await service.peers())
        .where((p) => !p.isGone && (self == null || p.deviceFingerprint != self))
        .toList();
    state = peers;
  }

  void _onEvent(PrivetEvent event) {
    switch (event) {
      case DeviceDiscoveredEvent(:final deviceFingerprint, :final deviceName):
        if (deviceFingerprint == _selfFingerprint) break; // our own beacon
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

/// Every trust record the daemon keeps — trusted AND revoked. `list_trusted`
/// deliberately returns revoked peers too (they stay for audit/history), and a
/// revoked peer is only ever cleared by forgetting it (the daemon rejects a
/// revoked peer's connections outright). The rest of the app shows just the
/// still-trusted subset via [trustedListProvider]; Settings watches this one so
/// a device that was banned can be forgotten again and re-paired.
final allTrustedListProvider = FutureProvider<List<TrustedPeerDto>>((ref) async {
  final service = ref.watch(daemonStateProvider).service;
  return await service?.trusted() ?? const [];
});

/// Pairing-completed peers (the daemon's trusted list). The daemon's
/// `list_trusted` keeps revoked peers in the trust store (they stay for
/// history), so surface only records whose trust state is still `Trusted` —
/// otherwise revoking a device (Settings → Remove Trust) never removes it.
final trustedListProvider = FutureProvider<List<TrustedPeerDto>>((ref) async {
  final service = ref.watch(daemonStateProvider).service;
  final peers = await service?.trusted() ?? const [];
  return peers.where((p) => p.trustState == 'Trusted').toList();
});
