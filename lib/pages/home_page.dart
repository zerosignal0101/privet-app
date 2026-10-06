import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../providers/pairing.dart';
import '../providers/peers.dart';
import '../providers/transfers.dart';
import '../services/ipc/dto.dart';
import '../services/pairing_url.dart';
import '../state/daemon_state.dart';
import '../utils/addr.dart';
import '../utils/format.dart';
import '../widgets/local_addresses.dart';
import '../widgets/pairing_banner.dart';
import '../widgets/transfer_tile.dart';
import 'send_preparation_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _showQr = false;

  /// Re-scans nearby devices and re-reads the trusted list. A discovery scan
  /// only repopulates "Nearby Devices", so "Known Devices" (the trusted list)
  /// is invalidated separately — otherwise the refresh button (the only refresh
  /// on desktop, where the pull-down gesture doesn't exist) would leave the
  /// known-device list stale.
  ///
  /// It then probes the remembered address of every trusted device that is not
  /// currently broadcasting, so a device that just received a file but does not
  /// beacon on this network stops looking permanently dead. The probe runs
  /// inside this future, which is what keeps the pull-down spinner up until the
  /// answer is in.
  Future<void> _refresh() async {
    await ref.read(peerListProvider.notifier).refresh();
    ref.invalidate(trustedListProvider);
    final trusted = await ref.read(trustedListProvider.future);
    await ref.read(reachabilityProvider.notifier).probeOnRefresh(
          trusted,
          ref.read(onlinePeerFingerprintsProvider),
        );
  }

  @override
  Widget build(BuildContext context) {
    final peers = ref.watch(peerListProvider);
    final pairingRequests = ref.watch(pairingProvider);
    final activeMap = ref.watch(activeTransfersProvider);
    final identity = ref.watch(identityProvider);
    final trusted = ref.watch(trustedListProvider);
    final status = ref.watch(daemonStatusProvider).value;

    // Reachable hosts for the pairing QR (skips wildcard/unspecified bindings).
    final hosts = <String>[
      for (final addr in [status?.quicAddr, status?.tcpAddr])
        if (addr != null && _isReachableHost(addr)) addr,
    ];

    // The daemon can discover this device itself (e.g. its own beacon on a
    // multi-homed NIC); never let "Nearby Devices" show or target us.
    final identityFp = identity.value?.deviceFingerprint;
    final nearbyPeers = peers
        .where((p) => p.deviceFingerprint != identityFp)
        .toList();

    // Trusted peers currently broadcasting are online and sendable; a trusted
    // peer that is not broadcasting is judged by the last refresh's address
    // probe instead (see ReachabilityNotifier), so a device that is reachable
    // at a remembered address without beaconing is not greyed out.
    final onlineFps = ref.watch(onlinePeerFingerprintsProvider);
    final reachability = ref.watch(reachabilityProvider);

    final activeList = activeMap.values.toList();
    final awaitingAccept = activeList.where((t) => t.isAwaitingAccept).toList();
    final transferring = activeList
        .where((t) =>
            t.state == TransferState.transferring ||
            t.state == TransferState.paused ||
            t.state == TransferState.reconnecting ||
            t.state == TransferState.preparing)
        .toList();
    final recent = activeList
        .where((t) =>
            t.state == TransferState.completed ||
            t.state == TransferState.failed ||
            t.state == TransferState.cancelled)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Privet'),
        actions: [
          // Desktop has no pull-to-refresh touch gesture (mouse only), so the
          // refresh button is the only way to re-scan; the pull-down is kept for
          // touch devices. Both trigger the same refresh.
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh devices',
            onPressed: _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: [
            _IdentityCard(
              identity: identity.value,
              hosts: hosts,
              showQr: _showQr,
              onToggleQr: () => setState(() => _showQr = !_showQr),
            ),

            // This machine's own dialable addresses. Always shown (even when
            // empty, which the section renders as a one-line notice) because
            // on a client-isolated network this is the only way a user can
            // pair: read the address here, type it into the other device.
            LocalAddressesSection(
              addrs: status?.localAddrs ?? const [],
            ),

            // Pairing requests
            if (pairingRequests.isNotEmpty)
              ...pairingRequests.map((req) => PairingBanner(
                    request: req,
                    onShowCode: () => _showMyCode(req.deviceFingerprint),
                    onDismiss: () =>
                        ref.read(pairingProvider.notifier).resolve(req.deviceFingerprint),
                  )),

            // Awaiting-accept offers
            if (awaitingAccept.isNotEmpty) ...[
              _sectionTitle(context, 'Incoming'),
              ...awaitingAccept.map((t) =>
                  TransferTile(key: ValueKey(t.transferId), transfer: t)),
            ],

            // Active transfers
            if (transferring.isNotEmpty) ...[
              _sectionTitle(context, 'Active Transfers'),
              ...transferring.map((t) =>
                  TransferTile(key: ValueKey(t.transferId), transfer: t)),
            ],

            // Recently finished
            if (recent.isNotEmpty) ...[
              _sectionTitle(context, 'Recent'),
              ...recent.map((t) =>
                  TransferTile(key: ValueKey(t.transferId), transfer: t)),
            ],

            // Known (trusted) devices
            _sectionTitle(context, 'Known Devices'),
            if (trusted.value?.isEmpty ?? true)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  'No trusted devices yet — pair to send files',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              )
            else
              ...(trusted.value ?? []).map((tp) {
                final probe =
                    reachability[tp.deviceFingerprint] ?? unknownReachability;
                final broadcasting = onlineFps.contains(tp.deviceFingerprint);
                // Discovery outranks a probe: a beaconing device needs no
                // address, and the remembered address may well be stale.
                return _TrustedPeerTile(
                  peer: tp,
                  state: broadcasting
                      ? TrustedReachability.online
                      : probe.state,
                  probing: !broadcasting &&
                      probe.state == TrustedReachability.probing,
                  // Sending to a device that is not broadcasting only works if
                  // the address is pinned, so the tile hands the probed
                  // address to the send page as `via`.
                  onSend: () => _navigateToSend(
                    tp.deviceFingerprint,
                    name: tp.deviceName,
                    via: broadcasting ? null : probe.address,
                  ),
                );
              }),

            // Nearby (discovered) devices
            _sectionTitle(context, 'Nearby Devices'),
            if (nearbyPeers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('Scanning for devices...')),
              )
            else
              ...nearbyPeers.map((peer) => _PeerTile(
                    peer: peer,
                    onSend: () => _navigateToSend(peer.deviceFingerprint,
                        name: peer.deviceName),
                  )),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _navigateToSend(null),
        child: const Icon(Icons.send),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  void _navigateToSend(String? fingerprint, {String? name, String? via}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SendPreparationPage(
          initialPeerFingerprint: fingerprint,
          initialPeerName: name,
          initialViaIp: via,
        ),
      ),
    );
  }

  void _showMyCode(String deviceFingerprint) {
    // The two-sided code exchange is wired in Plan 3 Task 9; for now surface
    // the request so the banner action has somewhere to go.
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pairing'),
        content: Text(
            'Device ${shortFingerprint(deviceFingerprint)} requested pairing.\n\n'
            'The code exchange flow is part of the next update.'),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Identity card — device name, fingerprint, QR pairing placeholder
// ---------------------------------------------------------------------------

class _IdentityCard extends StatelessWidget {
  final IdentityDto? identity;
  final List<String> hosts;
  final bool showQr;
  final VoidCallback onToggleQr;

  const _IdentityCard({
    this.identity,
    this.hosts = const [],
    required this.showQr,
    required this.onToggleQr,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fp = identity?.deviceFingerprint ?? '';
    final deviceName = identity?.deviceName ?? '…';

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.computer, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(deviceName,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                      if (fp.isNotEmpty)
                        Text(
                          shortFingerprint(fp),
                          style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                              fontFamily: 'monospace'),
                        ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: onToggleQr,
                  icon: Icon(showQr ? Icons.qr_code_2 : Icons.qr_code, size: 20),
                  label:
                      Text(showQr ? 'Hide' : 'Pair', style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
            if (showQr) ...[
              const SizedBox(height: 12),
              _PairingQrCode(
                fingerprint: fp,
                deviceName: deviceName,
                hosts: hosts,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Generates a fresh pairing code and renders the QR the other device scans to
/// pair with this device (`privet://pair?h=…&fp=…&n=…&code=…`).
class _PairingQrCode extends ConsumerStatefulWidget {
  final String fingerprint;
  final String deviceName;
  final List<String> hosts;

  const _PairingQrCode({
    required this.fingerprint,
    required this.deviceName,
    required this.hosts,
  });

  @override
  ConsumerState<_PairingQrCode> createState() => _PairingQrCodeState();
}

class _PairingQrCodeState extends ConsumerState<_PairingQrCode> {
  String? _code;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = ref.read(daemonStateProvider).service;
    String? code;
    if (service != null) {
      try {
        code = (await service.generatePairingCode()).code;
      } catch (_) {
        // daemon unreachable — fall through to the error state below
      }
    }
    if (mounted) {
      setState(() {
        _code = code;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final code = _code;
    if (code == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text('Could not generate a pairing code',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
        ),
      );
    }

    final url = PairingUrl.build(
      fingerprint: widget.fingerprint,
      deviceName: widget.deviceName,
      hosts: widget.hosts,
      code: code,
    );

    return Column(
      children: [
        QrImageView(
          data: url,
          version: QrVersions.auto,
          size: 180,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.black87,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.black87,
          ),
          padding: const EdgeInsets.all(4),
        ),
        const SizedBox(height: 8),
        Text('Code: $code',
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                letterSpacing: 2)),
        const SizedBox(height: 2),
        Text('Scan with the Privet app to pair',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Trusted peer tile
// ---------------------------------------------------------------------------

/// One row of Known Devices.
///
/// A device is not only "on the air or not": once a send has succeeded the
/// engine remembers the address it used, and that address can still answer long
/// after the device stopped beaconing. This row therefore shows the address
/// itself and, after a refresh, what probing it actually proved — so a device
/// that is reachable at a known address is never stuck greyed out, and one
/// whose address belongs to somebody else is never mistaken for a friend.
class _TrustedPeerTile extends StatelessWidget {
  final TrustedPeerDto peer;
  final TrustedReachability state;

  /// True while a probe for this row is in flight; the row says so instead of
  /// claiming an answer it does not have yet.
  final bool probing;

  final VoidCallback onSend;

  const _TrustedPeerTile({
    required this.peer,
    required this.state,
    required this.probing,
    required this.onSend,
  });

  /// The remembered address, bracketed if IPv6, or null when none is known.
  String? get _address {
    final ip = peer.addresses.isEmpty ? null : peer.addresses.first.ip;
    if (ip == null || ip.isEmpty) return null;
    return isIpv6Literal(ip) ? '[$ip]' : ip;
  }

  /// The status line. Says which address it is about, and — for the rejected
  /// cases — never claims the device is there.
  String get _statusText {
    final address = _address;
    return switch (state) {
      TrustedReachability.online => 'Online',
      TrustedReachability.probing =>
        address == null ? 'Checking…' : 'Checking $address…',
      TrustedReachability.reachable => 'Reachable at $address',
      // Deliberately identical for "nobody answered" and "something else
      // answered": both mean "not this device", and the copy must not imply
      // otherwise in the second case.
      TrustedReachability.unreachable => 'No answer at $address',
      TrustedReachability.unknown => 'Offline',
    };
  }

  Color get _statusColor => switch (state) {
        TrustedReachability.online => Colors.green.shade700,
        // Reachable is a real, verified answer — only weaker than a beacon, so
        // it stays green rather than being greyed out like the failures.
        TrustedReachability.reachable => Colors.green.shade700,
        TrustedReachability.probing => Colors.orange,
        TrustedReachability.unreachable => Colors.grey,
        TrustedReachability.unknown => Colors.grey,
      };

  @override
  Widget build(BuildContext context) {
    final address = _address;
    final sendable = state.canSend;
    return ListTile(
      dense: true,
      leading: probing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(Icons.verified_user, color: _statusColor, size: 20),
      title: Text(peer.deviceName, style: const TextStyle(fontSize: 14)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${shortFingerprint(peer.deviceFingerprint)} · $_statusText',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 11, color: _statusColor, fontFamily: 'monospace'),
          ),
          // The address is always visible when one is known, whatever the
          // state: "we tried it and nothing answered" is only actionable if
          // the user can see which address was tried.
          if (address != null)
            Text(address,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11, color: Colors.grey, fontFamily: 'monospace')),
        ],
      ),
      // Send is offered for a beaconing or verified-reachable device, and only
      // then — it is wired to send via the shown address, which is the only
      // thing that can work for a device that is not on the air.
      trailing: sendable
          ? IconButton(icon: const Icon(Icons.send, size: 18), onPressed: onSend)
          : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Nearby (discovered) peer tile
// ---------------------------------------------------------------------------

/// True when an `ip:port` address is a usable LAN host for a pairing QR
/// (skips wildcard / loopback / unspecified bindings).
bool _isReachableHost(String addr) {
  String ip;
  if (addr.startsWith('[')) {
    final end = addr.indexOf(']');
    if (end < 0) return false;
    ip = addr.substring(1, end);
  } else {
    ip = addr.split(':').first;
  }
  if (ip.isEmpty ||
      ip == '0.0.0.0' ||
      ip == '::' ||
      ip == '127.0.0.1' ||
      ip == '::1') {
    return false;
  }
  return true;
}

class _PeerTile extends StatelessWidget {
  final PeerDto peer;
  final VoidCallback onSend;

  const _PeerTile({required this.peer, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final addr = peer.candidates.isNotEmpty ? peer.candidates.first.ip : null;
    return ListTile(
      dense: true,
      leading: Icon(Icons.devices, size: 20, color: peer.isOnline ? null : Colors.grey),
      title: Text(peer.deviceName, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        peer.isOnline
            ? (addr ?? shortFingerprint(peer.deviceFingerprint))
            : 'Offline · ${addr ?? shortFingerprint(peer.deviceFingerprint)}',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: addr != null && peer.isOnline
              ? Colors.green.shade700
              : Colors.grey,
          fontFamily: 'monospace',
        ),
      ),
      trailing: peer.isOnline
          ? IconButton(icon: const Icon(Icons.send, size: 18), onPressed: onSend)
          : null,
    );
  }
}
