import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ipc/dto.dart';

/// "This Machine" section on the home page: every address the daemon reports
/// for this host, each with a copy button.
///
/// This exists for networks where automatic discovery cannot work — a campus
/// AP with client isolation, a VLAN that blocks multicast/UDP beacons. The
/// workaround is to read the address off one screen and type or paste it into
/// "pair by address" on the other, so the copied text must be exactly the
/// displayed text, in a form the pair-by-address parser accepts.
///
/// Every address the daemon reports is listed, not just the first: a host with
/// wired and wireless NICs has several, and which one the peer can reach depends
/// on their network, not ours. The daemon reports IPv4 only, which is what keeps
/// this a short list -- a phone on mobile data and Wi-Fi at once would otherwise
/// contribute a dozen IPv6 literals nobody is going to read off a screen.
class LocalAddressesSection extends StatelessWidget {
  final List<LocalAddrDto> addrs;

  const LocalAddressesSection({super.key, required this.addrs});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text('This Machine',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        if (addrs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'No local address available — connect to a network to pair by address',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          )
        else
          ...addrs.map((a) => _LocalAddrTile(addr: a)),
      ],
    );
  }
}

class _LocalAddrTile extends StatelessWidget {
  final LocalAddrDto addr;

  const _LocalAddrTile({required this.addr});

  @override
  Widget build(BuildContext context) {
    // The same string that is shown and copied, so a paste into the other
    // device's pair-by-address box resolves to exactly this address.
    final dial = addr.dialString;
    return ListTile(
      dense: true,
      leading: Icon(Icons.lan_outlined, size: 20, color: Theme.of(context).colorScheme.primary),
      title: Text(
        dial,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
      ),
      subtitle: Text(
        'QUIC ${addr.quicPort} · TCP ${addr.tcpPort}',
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.copy, size: 18),
        tooltip: 'Copy address',
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: dial));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Copied $dial'),
              duration: const Duration(seconds: 2),
            ),
          );
        },
      ),
    );
  }
}
