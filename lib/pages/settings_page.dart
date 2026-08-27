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
    final trusted = ref.watch(trustedListProvider);

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
          if (trusted.value?.isEmpty ?? true)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child:
                  Text('No trusted devices', style: TextStyle(color: Colors.grey)),
            )
          else
            ...(trusted.value ?? []).map((tp) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.verified_user, size: 20),
                  title: Text(tp.deviceName),
                  subtitle: Text(
                    shortFingerprint(tp.deviceFingerprint),
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 10, color: Colors.grey),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _confirmRevoke(context, ref, tp),
                  ),
                )),

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
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('App Device Name'),
        content: TextField(controller: controller),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
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

  Future<void> _confirmRevoke(
      BuildContext context, WidgetRef ref, TrustedPeerDto peer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Trust?'),
        content: Text('Revoke trust for ${peer.deviceName}?'),
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
      await ref
          .read(daemonStateProvider)
          .service
          ?.revokePeer(peer.deviceFingerprint);
      ref.invalidate(trustedListProvider);
    }
  }
}
