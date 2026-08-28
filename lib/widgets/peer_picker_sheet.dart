import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/peers.dart';

/// Bottom sheet for picking a peer to send files to. Nearby items return a
/// **fingerprint** — the daemon's `send` is keyed by trusted fingerprint.
/// "Send by Address" is a pair-by-address flow wired by the caller (Task 9).
class PeerPickerSheet extends ConsumerStatefulWidget {
  final void Function(String fingerprint, {String? name}) onSelected;
  final VoidCallback? onPairByAddress;

  const PeerPickerSheet({
    super.key,
    required this.onSelected,
    this.onPairByAddress,
  });

  static Future<void> show(
    BuildContext context, {
    required void Function(String fingerprint, {String? name}) onSelected,
    VoidCallback? onPairByAddress,
  }) {
    return showModalBottomSheet(
      context: context,
      builder: (_) => PeerPickerSheet(
        onSelected: onSelected,
        onPairByAddress: onPairByAddress,
      ),
    );
  }

  @override
  ConsumerState<PeerPickerSheet> createState() => _PeerPickerSheetState();
}

class _PeerPickerSheetState extends ConsumerState<PeerPickerSheet> {
  @override
  Widget build(BuildContext context) {
    final peers = ref.watch(peerListProvider);
    // The daemon can discover this device itself; never offer "us" as a target.
    final identityFp = ref.watch(identityProvider).value?.deviceFingerprint;
    final nearbyPeers =
        peers.where((p) => p.deviceFingerprint != identityFp).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Select Recipient',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            if (widget.onPairByAddress != null)
              ListTile(
                leading: const Icon(Icons.input),
                title: const Text('Send by Address'),
                subtitle: const Text('Pair by address, then send'),
                onTap: () {
                  Navigator.pop(context);
                  widget.onPairByAddress!();
                },
              ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Refresh Nearby'),
              subtitle: const Text('Re-scan the local network'),
              onTap: () => ref.read(peerListProvider.notifier).refresh(),
            ),
            if (nearbyPeers.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Nearby Devices',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              ...nearbyPeers.map((peer) => ListTile(
                    leading: const Icon(Icons.devices, size: 20),
                    title:
                        Text(peer.deviceName, style: const TextStyle(fontSize: 14)),
                    subtitle: Text(
                      _shortFp(peer.deviceFingerprint),
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    dense: true,
                    onTap: () {
                      Navigator.pop(context);
                      widget.onSelected(peer.deviceFingerprint,
                          name: peer.deviceName);
                    },
                  )),
            ],
            if (nearbyPeers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: Text(
                    'No devices found yet. Use "Refresh Nearby" to scan, '
                    'or "Send by Address" to pair manually.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _shortFp(String fp) =>
      fp.length > 16 ? '${fp.substring(0, 16)}…' : fp;
}
