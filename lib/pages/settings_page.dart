import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/peers.dart';
import '../providers/settings.dart';
import '../services/ipc/dto.dart';
import '../state/daemon_state.dart';
import '../utils/format.dart';

/// Settings bound to the daemon's live runtime config (via `settingsProvider`)
/// plus app-local prefs. Features dropped from the old app per the plan:
/// per-device auto-accept, known-device IP editing, network labels, TCP
/// fallback toggle and the 3-way security mode.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final identity = ref.watch(identityProvider);
    // The daemon's list_trusted returns both trusted and revoked records. The
    // trusted subset is what "Known Devices" elsewhere shows; Settings shows
    // both so a revoked device (which the daemon hard-rejects on reconnect) can
    // still be forgotten and re-paired. "Remove Trust" forgets rather than
    // revokes: forgetting un-pairs the device and lets it pair again, revoking
    // bans it until forgotten.
    final allTrusted = ref.watch(allTrustedListProvider);
    final trustedPeers = (allTrusted.value ?? const [])
        .where((p) => p.trustState == 'Trusted')
        .toList();
    final revokedPeers = (allTrusted.value ?? const [])
        .where((p) => p.trustState != 'Trusted')
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // Device identity (read-only, from the daemon)
          if (identity.value != null) ...[
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: const Text('Device Fingerprint'),
              subtitle: Text(
                shortFingerprint(identity.value!.deviceFingerprint),
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12, color: Colors.grey),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.badge),
              title: const Text('Device Name'),
              subtitle: Text(identity.value!.deviceName),
            ),
            const Divider(),
          ],

          // App-local device name (applied to the daemon config in Plan 4)
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('App Device Name'),
            subtitle: Text(settings.deviceName),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editDeviceName(context, ref, settings.deviceName),
          ),

          // Save directory (daemon runtime config)
          ListTile(
            leading: const Icon(Icons.folder),
            title: const Text('Save Directory'),
            subtitle: Text(
              settings.saveDir ?? 'Default',
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickSaveDir(ref),
          ),

          // Accept all trusted (daemon runtime config)
          SwitchListTile(
            secondary: const Icon(Icons.public),
            title: const Text('Accept All Trusted'),
            subtitle: const Text('Auto-accept transfers from any device'),
            value: settings.acceptAllTrusted,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setAcceptAllTrusted(v),
          ),

          // Collision policy (daemon runtime config)
          ListTile(
            leading: const Icon(Icons.drive_file_move_outline),
            title: const Text('Collision Policy'),
            subtitle: Text(settings.collisionPolicy),
            trailing: DropdownButton<String>(
              value: settings.collisionPolicy,
              onChanged: (v) {
                if (v != null) {
                  ref.read(settingsProvider.notifier).setCollisionPolicy(v);
                }
              },
              items: const ['rename', 'skip', 'overwrite']
                  .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                  .toList(),
            ),
          ),

          // Leave daemon running (app-local pref). Desktop only: on Android the
          // in-process daemon lives and dies with the process (pinned by the
          // foreground service), so the setting would have no effect.
          if (defaultTargetPlatform != TargetPlatform.android)
            SwitchListTile(
              secondary: const Icon(Icons.power_settings_new),
              title: const Text('Leave Daemon Running'),
              subtitle: const Text('Keep privetd alive after the app closes'),
              value: settings.leaveDaemonRunning,
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setLeaveDaemonRunning(v),
            ),

          const Divider(),

          // Trusted devices
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Trusted Devices',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          if (allTrusted.value?.isEmpty ?? true)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child:
                  Text('No trusted devices', style: TextStyle(color: Colors.grey)),
            )
          else ...[
            ...trustedPeers.map((tp) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.verified_user, size: 20),
                  title: Text(tp.deviceName),
                  subtitle: Text(
                    [
                      shortFingerprint(tp.deviceFingerprint),
                      // Newest remembered address, so the user can see which IP
                      // a previous successful send used (and reuse it verbatim
                      // in the send page when discovery is unavailable).
                      if (tp.latestAddress != null) tp.latestAddress!.dialString,
                    ].join('\n'),
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 10, color: Colors.grey),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Remove trust',
                    onPressed: () => _confirmRemove(context, ref, tp),
                  ),
                )),
            // Revoked peers are kept by the daemon and hard-rejected on
            // reconnect, so surface them here with a forget action — otherwise
            // a banned device can never be cleared to pair again.
            if (revokedPeers.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('Revoked Devices',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
              ),
              ...revokedPeers.map((tp) => ListTile(
                    dense: true,
                    leading: Icon(Icons.block, size: 20, color: Colors.grey),
                    title: Text(tp.deviceName),
                    subtitle: Text(
                      'Revoked — forget to allow pairing again',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: 'Forget revoked device',
                      onPressed: () => _confirmForget(context, ref, tp),
                    ),
                  )),
            ],
          ],

          const Divider(),

          // Daemon control
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Restart Daemon'),
            subtitle: const Text('Stop and start privetd'),
            onTap: () => ref.read(daemonStateProvider.notifier).restart(),
          ),
        ],
      ),
    );
  }

  Future<void> _editDeviceName(
      BuildContext context, WidgetRef ref, String current) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _DeviceNameDialog(initial: current),
    );
    if (name != null && name.isNotEmpty) {
      await ref.read(settingsProvider.notifier).setDeviceName(name);
    }
  }

  Future<void> _pickSaveDir(WidgetRef ref) async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      await ref.read(settingsProvider.notifier).setSaveDir(result);
    }
  }

  /// Un-pair a trusted device. This must call `forget_peer`, not `revoke_peer`:
  /// forgetting removes the trust record so the device becomes unknown again and
  /// can be paired fresh, whereas revoking leaves a `Revoked` row that the
  /// daemon hard-rejects on reconnect — which surfaced as "Pairing failed:
  /// quic read: connection lost" when the user scanned a QR after removing trust.
  Future<void> _confirmRemove(
      BuildContext context, WidgetRef ref, TrustedPeerDto peer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Trust?'),
        content: Text(
            'Remove ${peer.deviceName} from your trusted devices? '
            'You can pair it again anytime.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) {
      await _forgetPeer(ref, peer.deviceFingerprint);
    }
  }

  /// Clear a revoked (banned) device so it becomes unknown and can pair again.
  Future<void> _confirmForget(
      BuildContext context, WidgetRef ref, TrustedPeerDto peer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget revoked device?'),
        content: Text(
            '${peer.deviceName} is revoked and cannot connect. '
            'Forget it to allow pairing again?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Forget')),
        ],
      ),
    );
    if (confirmed == true) {
      await _forgetPeer(ref, peer.deviceFingerprint);
    }
  }

  Future<void> _forgetPeer(WidgetRef ref, String fingerprint) async {
    await ref
        .read(daemonStateProvider)
        .service
        ?.forgetPeer(fingerprint);
    ref.invalidate(allTrustedListProvider);
    ref.invalidate(trustedListProvider);
  }
}

/// A device-name alert dialog that owns its [TextEditingController] so the
/// controller outlives the route's exit animation. Disposing an external
/// controller as soon as `showDialog`'s future resolves (i.e. at
/// `Navigator.pop`) crashes the next rebuild of the still-fading-out `TextField`
/// ("A TextEditingController was used after being disposed", which cascades into
/// the `_dependents.isEmpty` framework assertion) — the controller must live
/// until the route subtree is unmounted, which happens in this State's
/// `dispose()`.
class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({required this.initial});

  final String initial;

  @override
  State<_DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('App Device Name'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(context, _controller.text),
            child: const Text('Save')),
      ],
    );
  }
}
