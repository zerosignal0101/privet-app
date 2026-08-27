import 'package:flutter/material.dart';

import '../providers/pairing.dart';

/// Shown on the home page when a peer requests pairing. The two-sided code
/// exchange itself lives in the send flow / pairing dialog (Plan 3 Task 9);
/// this banner surfaces the request and offers to show this device's code.
class PairingBanner extends StatelessWidget {
  final PairRequest request;
  final VoidCallback onShowCode;
  final VoidCallback onDismiss;

  const PairingBanner({
    super.key,
    required this.request,
    required this.onShowCode,
    required this.onDismiss,
  });

  String get _shortFp {
    final fp = request.deviceFingerprint;
    return fp.length > 16 ? '${fp.substring(0, 16)}…' : fp;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Pairing Request',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'A device wants to pair.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            Text(
              _shortFp,
              style: const TextStyle(
                  fontSize: 11, fontFamily: 'monospace', color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close, size: 14),
                  label: const Text('Dismiss', style: TextStyle(fontSize: 12)),
                ),
                FilledButton.icon(
                  onPressed: onShowCode,
                  icon: const Icon(Icons.qr_code, size: 14),
                  label: const Text('Show my code', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
