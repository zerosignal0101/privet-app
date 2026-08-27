import 'package:flutter/material.dart';

/// Temporary placeholder until the real send-preparation page + pairing flow
/// lands (Plan 3 Task 9).
class SendPreparationPage extends StatelessWidget {
  const SendPreparationPage({
    super.key,
    this.initialPeerFingerprint,
    this.initialPeerName,
  });

  final String? initialPeerFingerprint;
  final String? initialPeerName;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Send')),
        body: const Center(
            child: Text('Send preparation coming in the next update')),
      );
}
