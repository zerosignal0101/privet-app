import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ipc/dto.dart';
import '../services/ipc/events.dart';
import '../services/privet_service.dart';
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

// ---------------------------------------------------------------------------
// Reachability of trusted devices that are not broadcasting
// ---------------------------------------------------------------------------

/// How long one remembered address may be probed before the refresh gives up
/// on it. The daemon's own IPC request timeout is 30 s, which is far too long
/// to keep a pull-to-refresh spinner turning: an address nobody answers must
/// show its result, not hang the screen until the request times out.
const Duration kReachabilityProbeTimeout = Duration(seconds: 5);

/// What a refresh learned about one trusted device's remembered address.
///
/// This is deliberately *not* the same question as
/// [onlinePeerFingerprintsProvider]: discovery answers "is the device
/// broadcasting right now", this answers "does the address we remember still
/// answer, and is the thing answering the device we think it is".
enum TrustedReachability {
  /// The device is currently broadcasting and was discovered — the cheapest and
  /// strongest signal there is, and the one that needs no address at all.
  online,

  /// No address remembered, or never probed in this session — nothing is known
  /// beyond discovery.
  unknown,

  /// A probe is in flight for this device.
  probing,

  /// The remembered address answered, and the fingerprint it answered with is
  /// byte-for-byte the fingerprint of the row being rendered.
  reachable,

  /// The address was probed and did not yield *this* device: nobody answered,
  /// the probe failed/timed out, or something answered under a different
  /// identity.
  unreachable,
}

/// The "nothing probed yet" result, for rows with no address to probe.
const ReachabilityResult unknownReachability =
    ReachabilityResult(state: TrustedReachability.unknown);

extension SendabilityOnReachability on TrustedReachability {
  /// Whether a device in this state can be sent to right now. Only a beaconing
  /// device or one whose address answered as itself; anything else would send
  /// into a void or, worse, to whoever now holds that address.
  bool get canSend => switch (this) {
        TrustedReachability.online || TrustedReachability.reachable => true,
        TrustedReachability.unknown ||
        TrustedReachability.probing ||
        TrustedReachability.unreachable =>
          false,
      };
}

class ReachabilityResult {
  const ReachabilityResult({
    required this.state,
    this.address,
    this.probedFingerprint,
  });

  final TrustedReachability state;

  /// The address that was probed (bare IP, no port), when one was probed.
  final String? address;

  /// The fingerprint that actually answered, kept only so the UI can be honest
  /// about *why* an address was rejected. Never used as an identity on its own.
  final String? probedFingerprint;
}

/// Reachability of the trusted devices, probed on explicit user refresh only.
///
/// Discovery alone leaves a device that is not on the air looking permanently
/// dead, even though the engine has just remembered the address a successful
/// send used. So a refresh probes each trusted device that is not currently
/// broadcasting, at the address the daemon has on file, and keeps the answer
/// until the next refresh replaces it.
///
/// The fingerprint check is the load-bearing part: an address can be handed to
/// a different machine, and "something answered at the address I remember"
/// must never be rendered as "the device I trust is there" — that would offer
/// a Send button that delivers files to a stranger.
final reachabilityProvider =
    NotifierProvider<ReachabilityNotifier, Map<String, ReachabilityResult>>(
        ReachabilityNotifier.new);

class ReachabilityNotifier extends Notifier<Map<String, ReachabilityResult>> {
  /// Guards against a stale probe writing over a newer refresh's results, and
  /// against touching state after the container is gone.
  int _generation = 0;

  @override
  Map<String, ReachabilityResult> build() => const {};

  /// Probes every trusted device in [trusted] that is neither currently
  /// broadcasting ([online]) nor without a remembered address, all at once.
  ///
  /// Completes once every probe has answered or hit [kReachabilityProbeTimeout],
  /// so a device that never answers can delay the refresh by at most that
  /// bound — and cannot delay it per device, because the probes run in
  /// parallel rather than one timeout after another.
  Future<void> probeOnRefresh(
    List<TrustedPeerDto> trusted,
    Set<String> online,
  ) async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) {
      state = const {};
      return;
    }

    final targets = [
      for (final peer in trusted)
        if (!online.contains(peer.deviceFingerprint) && peer.addresses.isNotEmpty)
          (peer: peer, address: peer.addresses.first),
    ];

    if (targets.isEmpty) {
      state = const {};
      return;
    }

    final generation = ++_generation;
    state = {
      for (final t in targets)
        t.peer.deviceFingerprint: ReachabilityResult(
          state: TrustedReachability.probing,
          address: t.address.ip,
        ),
    };

    await Future.wait([
      for (final t in targets)
        _probe(service, t.peer.deviceFingerprint, t.address, generation),
    ]);

    // A newer refresh started while these were in flight: its results are the
    // ones on screen, so drop these on the floor rather than overwrite them.
    if (generation != _generation) return;

    // Recompute reachability from whatever the individual probes recorded, so
    // one device's slow answer cannot clobber another's already-known result.
    final results = <String, ReachabilityResult>{};
    for (final t in targets) {
      final pending = state[t.peer.deviceFingerprint];
      if (pending == null) continue;
      results[t.peer.deviceFingerprint] = pending.state == TrustedReachability.probing
          // Nothing wrote a verdict for this one: it fell through the timeout
          // path below without recording a result.
          ? ReachabilityResult(
              state: TrustedReachability.unreachable,
              address: t.address.ip,
            )
          : pending;
    }
    state = results;
  }

  Future<void> _probe(
    PrivetService service,
    String fingerprint,
    TrustedPeerAddressDto address,
    int generation,
  ) async {
    TrustedReachability outcome;
    String? answered;
    try {
      // The bound is passed to the daemon request itself, not wrapped around
      // it: an outer `.timeout` would let the app move on while a 30 s IPC
      // timer kept running (and a late reply would resolve an abandoned
      // completer), so the probe would still pin a timer for far longer than
      // the refresh it belongs to.
      final resolved = await service.resolveAddress(address.ip,
          quicPort: address.quicPort,
          tcpPort: address.tcpPort,
          timeout: kReachabilityProbeTimeout);
      answered = resolved.deviceFingerprint;
      // Exact match, or nothing. A different identity at the remembered
      // address is treated exactly like no answer: it is not the device this
      // row is about.
      outcome = resolved.found && answered == fingerprint
          ? TrustedReachability.reachable
          : TrustedReachability.unreachable;
    } catch (_) {
      // The daemon refused the request or the probe timed out. Either way this
      // address is not usable right now; the row must show that rather than
      // stay stuck on "probing".
      outcome = TrustedReachability.unreachable;
    }

    // A newer refresh may own the state now; writing then would resurrect a
    // stale verdict.
    if (_generation != generation) return;
    final current = state[fingerprint];
    if (current == null) return; // the device left the trusted list mid-probe
    state = {
      ...state,
      fingerprint: ReachabilityResult(
        state: outcome,
        address: address.ip,
        probedFingerprint: answered,
      ),
    };
  }
}
