import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/file_tree.dart';
import '../providers/peers.dart';
import '../providers/send_preparation.dart';
import '../providers/settings.dart';
import '../services/android/content_uri_dir_helper.dart';
import '../services/clipboard_service.dart';
import '../services/ipc/dto.dart';
import '../state/daemon_state.dart';
import '../utils/addr.dart';
import '../utils/format.dart';
import '../widgets/file_tree_view.dart';
import '../widgets/peer_picker_sheet.dart';

/// Multi-file send preparation screen: pick a trusted recipient (or pair with
/// an unknown one via the two-sided code flow), add files, then send. The
/// daemon's `send` takes top-level paths; the page waits on the transfer's
/// terminal event before popping back to Home.
class SendPreparationPage extends ConsumerStatefulWidget {
  const SendPreparationPage({
    super.key,
    this.initialPeerFingerprint,
    this.initialPeerName,
    this.initialViaIp,
    this.initialFilePaths,
    this.initialEntries,
  });

  final String? initialPeerFingerprint;
  final String? initialPeerName;

  /// Address to send through, pre-filled into the address box. Set when the
  /// user came from a Known Devices row that is not on the air but was just
  /// verified at a remembered address: without it the send would have no way to
  /// resolve the device and would fail even though the row says it is
  /// reachable.
  final String? initialViaIp;

  /// Pre-filled top-level paths (e.g. resend from history).
  final List<String>? initialFilePaths;

  /// Pre-built entries with preserved relative paths (e.g. history Forward).
  final List<SendFileEntry>? initialEntries;

  @override
  ConsumerState<SendPreparationPage> createState() => _SendPreparationPageState();
}

class _SendPreparationPageState extends ConsumerState<SendPreparationPage> {
  bool _initialised = false;
  // daemon QUIC_PORT / TCP_PORT, used when the user types a bare IP
  static const int _defaultPort = kDefaultPort;

  void _showSnackBar(String message,
      {Duration duration = const Duration(seconds: 2)}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: duration,
      behavior: SnackBarBehavior.floating,
      margin: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewPadding.bottom + 80,
      ),
    ));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Each open is a fresh intent: clear whatever a previous page left in the
      // (app-level) provider so initialParams actually apply. Otherwise the
      // guard `s.entries.isEmpty` / `s.peerFingerprint == null` below skips the
      // preloaded files and peer (e.g. after a completed send).
      ref.read(sendPreparationProvider.notifier).reset();
      _initFromParams();
    });
  }

  void _initFromParams() {
    if (_initialised) return;
    _initialised = true;
    final n = ref.read(sendPreparationProvider.notifier);
    final s = ref.read(sendPreparationProvider);

    if (widget.initialEntries != null &&
        widget.initialEntries!.isNotEmpty &&
        s.entries.isEmpty) {
      final existing = widget.initialEntries!
          .where((e) => File(e.path).existsSync())
          .toList();
      final missing = widget.initialEntries!.length - existing.length;
      for (final e in existing) {
        n.addFileEntry(e);
      }
      if (missing > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showSnackBar('$missing file(s) were missing and removed');
        });
      }
    } else if (widget.initialFilePaths != null &&
        widget.initialFilePaths!.isNotEmpty &&
        s.entries.isEmpty) {
      final existing =
          widget.initialFilePaths!.where((p) => File(p).existsSync()).toList();
      final missing = widget.initialFilePaths!.length - existing.length;
      n.addFiles(existing);
      if (missing > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showSnackBar('$missing file(s) were missing and removed');
        });
      }
    }

    if (widget.initialPeerFingerprint != null && s.peerFingerprint == null) {
      n.setPeer(widget.initialPeerFingerprint!, name: widget.initialPeerName);
      // Pin the address the caller already verified. Set after the peer (a
      // peer-less state discards the via on reset) and only when the address is
      // the one the row actually probed, so the send goes to the device that
      // answered rather than to whatever the engine resolves on its own.
      if (widget.initialViaIp != null && widget.initialViaIp!.isNotEmpty) {
        n.setVia(widget.initialViaIp!);
      }
    }
  }

  Future<bool> _onWillPop() async {
    final s = ref.read(sendPreparationProvider);
    if (s.rootPaths.isEmpty) {
      ref.read(sendPreparationProvider.notifier).clearFiles();
      return true;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard file selection?'),
        content: const Text('You have selected files. Discard them?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    if (confirmed == true) {
      // Discarding also deletes the Android staging copies that were staged but
      // never sent, so an abandoned selection can't bloat the app cache.
      await ref.read(sendPreparationProvider.notifier).discardSelection();
    }
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sendPreparationProvider);
    final trusted = ref.watch(trustedListProvider);
    final trustedPeers = trusted.value ?? const <TrustedPeerDto>[];
    final trustedFps = trustedPeers.map((t) => t.deviceFingerprint).toSet();
    final needsPairing = state.peerFingerprint != null &&
        !trustedFps.contains(state.peerFingerprint);
    // Addresses the daemon has remembered for the selected recipient, newest
    // first. Drives both the pre-filled "address" box and the chips offering
    // the other entries.
    final selectedPeer = state.peerFingerprint == null
        ? null
        : trustedPeers
            .where((t) => t.deviceFingerprint == state.peerFingerprint)
            .firstOrNull;
    // A trusted recipient that is not currently discovered is offline — the send
    // must not go through (the daemon would only spin against a dead address).
    final onlineFps = ref.watch(onlinePeerFingerprintsProvider);
    final selectedPeerOffline = state.peerFingerprint != null &&
        !needsPairing &&
        !onlineFps.contains(state.peerFingerprint);

    final body = Column(
      children: [
        _RecipientSection(
          peerName: state.peerName,
          peerFingerprint: state.peerFingerprint,
          offline: selectedPeerOffline,
          onChangeTap: () => _pickPeer(context, ref),
        ),
        // The address box only makes sense for an already-trusted device: the
        // engine needs a trust record to send through, and an untrusted peer
        // has to pair first.
        if (!needsPairing && state.peerFingerprint != null)
          _ViaAddressSection(
            key: ValueKey('via-${state.peerFingerprint}'),
            remembered: selectedPeer?.addresses ?? const [],
            viaIp: state.viaIp,
            error: state.viaError,
            onChanged: (value) =>
                ref.read(sendPreparationProvider.notifier).setVia(value),
          ),
        const Divider(height: 1),

        if (needsPairing)
          _PairingCard(
            deviceFingerprint: state.peerFingerprint!,
            onShowMyCode: _showMyCode,
            onEnterTheirCode: () => _enterTheirCodeFor(state.peerFingerprint!),
          ),

        if (selectedPeerOffline)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.cloud_off, size: 14, color: Colors.orange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    // With an address pinned the offline state is expected, not
                    // an error: that is exactly the isolation case `via` exists
                    // for, so the copy must not talk the user out of sending.
                    state.viaIp != null
                        ? '${state.peerName ?? 'This device'} is not '
                            'discoverable — sending to ${state.viaIp} anyway.'
                        : '${state.peerName ?? 'This device'} is offline — turn '
                            'it on, enter its address to send without '
                            'discovery, or choose another recipient.',
                    style: const TextStyle(
                        color: Colors.orange, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),

        if (state.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(state.error!,
                style: const TextStyle(color: Colors.red, fontSize: 13)),
          ),

        Expanded(
          child: state.entries.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 60),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.note_add, size: 48,
                              color: Colors.grey.shade300),
                          const SizedBox(height: 12),
                          const Text('No files selected',
                              style: TextStyle(color: Colors.grey)),
                        ],
                      ),
                    ),
                    _buildAddButtons(ref),
                  ],
                )
              : ListView(
                  children: [
                    _FileTreeSection(
                      entries: state.entries,
                      onRemove: (relPath) => ref
                          .read(sendPreparationProvider.notifier)
                          .removeByRelativePath(relPath),
                    ),
                    _buildAddButtons(ref),
                  ],
                ),
        ),
        const Divider(height: 1),
        _BottomBar(
          fileCount: state.rootPaths.length,
          sending: state.sending,
          onSend: state.isReady ? () => _send(ref) : null,
        ),
      ],
    );

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.keyV &&
              (HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isMetaPressed)) {
            _pasteFromClipboard(ref);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final shouldPop = await _onWillPop();
          if (shouldPop && context.mounted) Navigator.pop(context);
        },
        child: Scaffold(
          appBar: AppBar(title: const Text('Send Files')),
          body: body,
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Recipient selection
  // -------------------------------------------------------------------------

  void _pickPeer(BuildContext context, WidgetRef ref) {
    PeerPickerSheet.show(
      context,
      onSelected: (fp, {name}) =>
          ref.read(sendPreparationProvider.notifier).setPeer(fp, name: name),
      onSendByAddress: () => _sendByAddress(context, ref),
    );
  }

  /// Send-by-address flow: ask for an IP (port optional), then decide whether
  /// this is a send or a pairing.
  ///
  /// This is the manual counterpart to discovery, for networks where beacons
  /// don't get through (AP client isolation). The address the other device's
  /// "This Machine" section copies is exactly what is accepted here.
  ///
  /// The address is dialled *before* any code is requested: the daemon completes
  /// the same identity handshake pairing performs before it asks for a code, and
  /// that is what says who is there. Matching the address against the addresses
  /// remembered for known devices is not enough — a peer paired on one network
  /// and met again on another sits at an address nothing local has ever
  /// recorded, so a lookup finds nothing while the device is plainly reachable.
  ///
  /// A device that answers and is already trusted is sent to directly; a code is
  /// asked for only when something answers that this daemon does not already
  /// have, which is the one case where a code is the only way to learn who is on
  /// the other end.
  Future<void> _sendByAddress(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<({String? value, bool ok, String? error})>(
      context: context,
      builder: (ctx) => _TextEntryDialog(
        title: 'Send by Address',
        label: 'IP:Port',
        hint: '10.29.210.120  (port optional)',
        helper: 'Port is optional — omit it to use $kDefaultPort. '
            'IPv6 looks like [fe80::1]:$kDefaultPort. '
            'A device you already paired with is sent to directly; only a new '
            'one asks for its pairing code.',
        submitLabel: 'Next',
        onSubmit: (value) async => (value: value, ok: true, error: null),
      ),
    );
    final address = result?.value;
    if (address == null || address.isEmpty) return;

    final parsed = parseDialString(address, defaultPort: _defaultPort);
    if (parsed == null) {
      if (mounted) {
        _showSnackBar('Could not read that address — expected IP or IP:Port');
      }
      return;
    }

    // Ask the daemon who is at this address. Nothing local can answer it: the
    // remembered addresses of a device paired elsewhere point at the network it
    // was paired on, and a peer that is not on the air here is absent from the
    // candidate list too. The handshake is the only thing that knows.
    final service = ref.read(daemonStateProvider).service;
    if (service == null) return;

    // A port the user typed is an instruction; an omitted one is not. Leaving it
    // null lets the daemon dial its own listener ports, which is what a peer
    // built the same way answers on.
    final typedPort = hasExplicitPort(address);
    final ResolvedAddressDto resolved;
    try {
      resolved = await service.resolveAddress(
        parsed.ip,
        quicPort: typedPort ? parsed.port : null,
        tcpPort: typedPort ? parsed.port : null,
      );
    } catch (e) {
      if (mounted) _showSnackBar('Could not reach ${parsed.ip}: $e');
      return;
    }

    if (!resolved.found) {
      // Not an error, and not a pairing: nothing is there to pair with either.
      if (mounted) {
        _showSnackBar('No device answered at ${parsed.ip}. Check the address, '
            'and that the other device is running and reachable from here.');
      }
      return;
    }

    final notifier = ref.read(sendPreparationProvider.notifier);
    if (resolved.trusted) {
      final fingerprint = resolved.deviceFingerprint;
      if (fingerprint == null) {
        // Trust without an identity should not be possible; if it ever happens,
        // inventing one is the last thing to do.
        if (mounted) {
          _showSnackBar('That address answered as trusted but reported no '
              'device identity — not sending.');
        }
        return;
      }
      final name = resolved.deviceName ?? parsed.ip;
      notifier.setPeer(fingerprint, name: name);
      notifier.setVia(parsed.ip);
      if (mounted) {
        _showSnackBar('$name is already paired — sending to ${parsed.ip}');
      }
      return;
    }

    // Something is there, but it is not a device this one has: a code is the
    // only way to learn who it is. The ports that just answered are the ones to
    // pair on.
    //
    // The dialog names the answerer first. A bare code prompt cannot tell the
    // user "this really is a different identity" from "the device I already
    // paired did not get recognised", and those two look identical from here —
    // both are just a box asking for six digits. Showing the name and enough of
    // the fingerprint to match against Known Devices turns the prompt into
    // something the user can check before entering anything.
    final notice = describeUnpairedAnswerer(
      name: resolved.deviceName ?? parsed.ip,
      fingerprint: resolved.deviceFingerprint,
      address: parsed.ip,
    );
    final ok = await _enterTheirCode(
      title: 'Enter Pairing Code',
      notice: notice,
      onPair: (code) => service.pair(
          ip: parsed.ip,
          quicPort: resolved.quicPort,
          tcpPort: resolved.tcpPort,
          code: code),
    );
    if (ok && mounted) _showSnackBar('Paired with ${parsed.ip}');
  }

  /// Side B of the code exchange against a selected (untrusted) fingerprint.
  Future<void> _enterTheirCodeFor(String fingerprint) async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) return;
    await _enterTheirCode(
        onPair: (code) => service.pair(fingerprint: fingerprint, code: code));
  }

  /// Two-sided pairing, side A: display this device's generated code so the
  /// remote device can enter it.
  Future<void> _showMyCode() async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) return;
    try {
      final code = await service.generatePairingCode();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Pairing Code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('On the other device, enter this code:'),
              const SizedBox(height: 12),
              Text(
                code.code,
                style: TextStyle(
                  fontSize: 32,
                  letterSpacing: 6,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text('Valid for ${code.validitySecs} seconds',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) _showSnackBar('Could not generate a pairing code: $e');
    }
  }

  /// Two-sided pairing, side B: the user types the code the remote device is
  /// displaying, and [onPair] completes the exchange with the daemon.
  Future<bool> _enterTheirCode({
    String title = 'Enter Their Code',
    String? notice,
    required Future<dynamic> Function(String code) onPair,
  }) async {
    final result = await showDialog<({String? value, bool ok, String? error})>(
      context: context,
      builder: (ctx) => _TextEntryDialog(
        title: title,
        notice: notice == null ? null : _AnswererNotice(notice),
        label: '6-digit code',
        hint: '123456',
        submitLabel: 'Pair',
        keyboardType: TextInputType.number,
        onSubmit: (code) async {
          final res = await onPair(code);
          final paired = res != null && (res as dynamic).paired == true;
          return (value: code, ok: paired, error: paired ? null : 'Code rejected');
        },
      ),
    );

    if (result == null) return false;
    if (result.ok) {
      ref.invalidate(trustedListProvider);
      return true;
    }
    if (mounted) _showSnackBar(result.error ?? 'Pairing failed');
    return false;
  }

  // -------------------------------------------------------------------------
  // File picking
  // -------------------------------------------------------------------------

  Widget _buildAddButtons(WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickFiles(ref),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add files'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickFolder(ref),
                  icon: const Icon(Icons.create_new_folder, size: 18),
                  label: const Text('Add folder'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pasteFromClipboard(ref),
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('Paste'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _createTextFile(ref),
                  icon: const Icon(Icons.text_fields, size: 18),
                  label: const Text('Create text'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickFiles(WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null && result.files.isNotEmpty) {
      final paths = result.files.map((f) => f.path!).toList();
      ref.read(sendPreparationProvider.notifier).addFiles(paths);
    }
  }

  Future<void> _pickFolder(WidgetRef ref) async {
    if (Platform.isAndroid) {
      // SAF tree picker (ACTION_OPEN_DOCUMENT_TREE) is more reliable on Android
      // than file_picker's directory picker. It caches the tree to real paths
      // (the daemon only reads real paths) and returns the cached root dir,
      // which we hand to addFiles — the daemon recurses directories itself.
      // Staging copies are cleaned up per-transfer (and when a selection is
      // discarded/removed), so no blanket wipe here — that would delete files a
      // still-running transfer is reading.
      final root = await ContentUriDirectoryHelper.pickAndCacheDirectory();
      if (root != null) {
        ref.read(sendPreparationProvider.notifier).addFiles([root]);
      }
      return;
    }
    final dirPath = await FilePicker.platform.getDirectoryPath();
    if (dirPath != null) {
      ref.read(sendPreparationProvider.notifier).addFiles([dirPath]);
    }
  }

  Future<void> _pasteFromClipboard(WidgetRef ref) async {
    try {
      final paths = await ClipboardService.readFilePaths();
      if (paths != null && paths.isNotEmpty) {
        ref.read(sendPreparationProvider.notifier).addFiles(paths);
        if (mounted) _showSnackBar('Pasted ${paths.length} file(s)');
        return;
      }
      final dir = await _defaultTargetDir(ref);
      final saved = await ClipboardService.saveToFile(dir);
      if (saved == null) {
        if (mounted) {
          _showSnackBar('Clipboard is empty or contains unsupported content');
        }
        return;
      }
      ref
          .read(sendPreparationProvider.notifier)
          .addFileEntry(SendFileEntry(
              path: saved.absolutePath,
              relativePath: saved.relativePath,
              size: saved.size));
      if (mounted) _showSnackBar('Pasted: ${saved.relativePath}');
    } catch (e) {
      if (mounted) _showSnackBar('Failed to paste: $e');
    }
  }

  Future<void> _createTextFile(WidgetRef ref) async {
    final nameCtrl = TextEditingController();
    final contentCtrl = TextEditingController();

    final result = await showDialog<({String name, String content})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Text File'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'File name (optional)',
                hintText: 'Leave empty for auto-name',
                suffixText: '.txt',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: contentCtrl,
              decoration: const InputDecoration(
                labelText: 'Content',
                border: OutlineInputBorder(),
              ),
              maxLines: 6,
              minLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (contentCtrl.text.trim().isEmpty) return;
              Navigator.pop(
                  ctx, (name: nameCtrl.text, content: contentCtrl.text));
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    contentCtrl.dispose();

    if (result == null) return;
    try {
      final rawName = result.name.trim();
      final fileName = rawName.isNotEmpty
          ? rawName.replaceAll(RegExp(r'[^\w\-_. ()]'), '')
          : ClipboardService.textFilename(result.content);
      final dir = await _defaultTargetDir(ref);
      final (path: filePath, relativePath: relPath) =
          ClipboardService.uniqueFile(dir, '$fileName.txt');
      await File(filePath).writeAsString(result.content);
      ref
          .read(sendPreparationProvider.notifier)
          .addFileEntry(SendFileEntry(
              path: filePath,
              relativePath: relPath,
              size: await File(filePath).length()));
      if (mounted) _showSnackBar('Created: $relPath');
    } catch (e) {
      if (mounted) _showSnackBar('Failed to create file: $e');
    }
  }

  Future<String> _defaultTargetDir(WidgetRef ref) async {
    final saveDir = ref.read(settingsProvider).saveDir;
    if (saveDir != null && saveDir.isNotEmpty) return saveDir;
    return (await getApplicationDocumentsDirectory()).path;
  }

  // -------------------------------------------------------------------------
  // Send
  // -------------------------------------------------------------------------

  Future<void> _send(WidgetRef ref) async {
    final s = ref.read(sendPreparationProvider);
    final onlineFps = ref.read(onlinePeerFingerprintsProvider);
    final fp = s.peerFingerprint;
    // Guard against sending to a recipient that is not currently online: the
    // daemon would only retry a dead address and end in a confusing "Internal
    // Error" tile or a bare Failed history row. Give a clear message instead.
    //
    // An explicit address is the documented way out: a device that cannot be
    // discovered (client isolation, a beacon-blocking VLAN) is permanently
    // "offline" here while being perfectly reachable by IP, so the offline gate
    // must not apply once the user has pinned an address.
    if (fp != null && !onlineFps.contains(fp) && s.viaIp == null) {
      ref.read(sendPreparationProvider.notifier).setError(
            '${s.peerName ?? 'The selected device'} is offline — it can\'t '
            'receive files right now. Make sure it is running and on the same '
            'network, then try again, or enter its address below to send '
            'without discovery.',
          );
      return;
    }
    final notifier = ref.read(sendPreparationProvider.notifier);
    final id = await notifier.send();
    if (id == null) return; // error already surfaced in state
    if (!mounted) return;
    // The transfer is queued — go back to Home immediately and let the transfer
    // tile report progress. The send page has no sending state.
    Navigator.of(context).popUntil((r) => r.isFirst);
    notifier.clearFiles();
  }
}

// ---------------------------------------------------------------------------
// Recipient section
// ---------------------------------------------------------------------------

class _RecipientSection extends StatelessWidget {
  final String? peerName;
  final String? peerFingerprint;
  final bool offline;
  final VoidCallback onChangeTap;

  const _RecipientSection({
    this.peerName,
    this.peerFingerprint,
    this.offline = false,
    required this.onChangeTap,
  });

  @override
  Widget build(BuildContext context) {
    final fp = peerFingerprint;
    return ListTile(
      leading: Icon(
        offline ? Icons.cloud_off : Icons.person,
        color: offline ? Colors.orange : null,
      ),
      title: Text(peerName ?? 'No recipient selected'),
      subtitle: fp != null
          ? Text(offline ? '${shortFingerprint(fp)} · offline' : shortFingerprint(fp))
          : null,
      trailing: TextButton(onPressed: onChangeTap, child: const Text('Change')),
    );
  }
}

// ---------------------------------------------------------------------------
// Send-to-address section
// ---------------------------------------------------------------------------

/// Lets the user pin the send to a specific IP of an already-trusted device.
///
/// This is the escape hatch for networks where discovery cannot work — a campus
/// AP with client isolation, a VLAN that blocks the beacon — where the device is
/// paired but never shows up as "online", so discovery has nothing to dial. The
/// daemon remembers the address after a successful transfer, so the box is
/// pre-filled with the newest remembered one and the common case needs no typing
/// at all.
///
/// The port is intentionally ignored: the engine reads it from the device record
/// it already holds, so only the bare IP is forwarded as `via`.
class _ViaAddressSection extends StatefulWidget {
  const _ViaAddressSection({
    super.key,
    required this.remembered,
    required this.viaIp,
    required this.error,
    required this.onChanged,
  });

  final List<TrustedPeerAddressDto> remembered;
  final String? viaIp;
  final String? error;
  final ValueChanged<String> onChanged;

  @override
  State<_ViaAddressSection> createState() => _ViaAddressSectionState();
}

class _ViaAddressSectionState extends State<_ViaAddressSection> {
  late final TextEditingController _controller = TextEditingController();
  bool _prefilled = false;

  @override
  void initState() {
    super.initState();
    _schedulePrefill();
  }

  @override
  void didUpdateWidget(covariant _ViaAddressSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-prefill when the daemon reports a different set of remembered
    // addresses for the same device (e.g. a background list_trusted refresh
    // returning a newer entry).
    if (oldWidget.remembered != widget.remembered) {
      _schedulePrefill();
    }
  }

  /// Seeds the box once per recipient.
  ///
  /// Two sources, in this order of authority:
  ///
  ///  * a `via` that is already set — the user typed an address in the
  ///    send-by-address flow, and that is the address they mean. It must win over
  ///    whatever the trust store remembers, because the whole point of typing one
  ///    is that the remembered address is wrong (a device met again on another
  ///    network). Letting the prefill overwrite it would silently send to the old
  ///    address, which is the failure this box is here to avoid.
  ///  * otherwise the device's newest remembered address.
  ///
  /// The provider write is deferred to a post-frame callback on purpose:
  /// `onChanged` mutates [sendPreparationProvider], and Riverpod forbids
  /// touching a provider during the build/lifecycle phase. It also means the
  /// first frame renders the (empty) box before the prefill lands.
  ///
  /// After this has run once, the user's own text wins — a later refresh must
  /// not overwrite what they typed or clear their edit.
  void _schedulePrefill() {
    if (_prefilled) return;

    // Already decided: show it, and leave the provider alone — it was the thing
    // that set the value.
    final chosen = widget.viaIp;
    if (chosen != null) {
      _prefilled = true;
      _controller.text = chosen;
      return;
    }

    final latest = widget.remembered.isEmpty ? null : widget.remembered.first;
    if (latest == null) return;
    _prefilled = true;
    // Prefill the bare IP: the port in the record is what the engine dials, and
    // showing it would suggest it needs to be typed too.
    final ip = latest.ip;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.text = ip;
      widget.onChanged(ip);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final err = widget.error;
    final others = widget.remembered.length > 1
        ? widget.remembered.skip(1).toList()
        : const <TrustedPeerAddressDto>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.alternate_email, size: 16, color: Colors.grey),
              const SizedBox(width: 6),
              Text(
                'Send to address',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('via-address-field'),
            controller: _controller,
            onChanged: widget.onChanged,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: 'Leave empty to use the remembered address',
              errorText: err,
              errorMaxLines: 2,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Use this when the device cannot be discovered on this network '
            '(e.g. Wi-Fi with client isolation). The address is remembered '
            'after a successful send, so it is suggested next time. The port '
            'comes from the device record — only the IP is sent.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          if (others.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: others
                  .map((a) => ActionChip(
                        avatar: const Icon(Icons.history, size: 14),
                        label: Text(a.ip,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11)),
                        tooltip: 'Use ${a.ip}',
                        onPressed: () {
                          _controller.text = a.ip;
                          widget.onChanged(a.ip);
                        },
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pairing card — shown when the selected recipient is not trusted
// ---------------------------------------------------------------------------

class _PairingCard extends StatelessWidget {
  final String deviceFingerprint;
  final VoidCallback onShowMyCode;
  final VoidCallback onEnterTheirCode;

  const _PairingCard({
    required this.deviceFingerprint,
    required this.onShowMyCode,
    required this.onEnterTheirCode,
  });

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
            Row(
              children: [
                const Icon(Icons.shield, size: 18, color: Colors.orange),
                const SizedBox(width: 8),
                Text('Pairing required',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange.shade800)),
              ],
            ),
            const SizedBox(height: 4),
            Text('Trust ${shortFingerprint(deviceFingerprint)} to send files?',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  onPressed: onShowMyCode,
                  icon: const Icon(Icons.qr_code, size: 14),
                  label: const Text('Show my code',
                      style: TextStyle(fontSize: 12)),
                ),
                FilledButton.icon(
                  onPressed: onEnterTheirCode,
                  icon: const Icon(Icons.pin, size: 14),
                  label: const Text('Enter their code',
                      style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// File tree section
// ---------------------------------------------------------------------------

class _FileTreeSection extends StatelessWidget {
  final List<SendFileEntry> entries;
  final void Function(String relativePath) onRemove;

  const _FileTreeSection({required this.entries, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return FileTreeView(
      nodes: _buildTree(entries),
      showRemoveButtons: true,
      onRemoveFile: onRemove,
      formatSize: _formatSize,
    );
  }

  /// Build a tree from the flat entries list, using `isDir` to mark directory
  /// nodes and carrying each leaf's absolute path for display.
  List<FileTreeNode> _buildTree(List<SendFileEntry> entries) {
    final filePaths = <String>[];
    final dirSet = <String>{};
    for (final e in entries) {
      if (e.isDir) {
        dirSet.add(e.relativePath);
      } else {
        filePaths.add(e.relativePath);
      }
    }

    final lookup = <String, List<String>>{};
    for (final path in filePaths) {
      final parts = path.split('/');
      if (parts.isEmpty) continue;
      final fileName = parts.last;
      final dirParts = parts.sublist(0, parts.length - 1);
      final dirKey = dirParts.join('/');
      lookup.putIfAbsent(dirKey, () => []).add(fileName);
    }
    for (final dirPath in dirSet) {
      final parts = dirPath.split('/');
      for (int i = 0; i < parts.length; i++) {
        final prefix = parts.sublist(0, i).join('/');
        lookup.putIfAbsent(prefix, () => []);
      }
    }

    final sizeMap = <String, int>{};
    final absPathMap = <String, String>{};
    for (final e in entries) {
      sizeMap[e.relativePath] = e.size;
      absPathMap[e.relativePath] = e.path;
    }

    return _buildTreeNodes(lookup, '', dirSet, sizeMap, absPathMap);
  }

  List<FileTreeNode> _buildTreeNodes(
      Map<String, List<String>> lookup,
      String prefix,
      Set<String> dirSet,
      Map<String, int> sizeMap,
      Map<String, String> absPathMap) {
    final result = <FileTreeNode>[];
    final dirs = <String>{};
    final files = <String>[];

    for (final entry in lookup.entries) {
      final dirPath = entry.key;
      if (dirPath == prefix) {
        for (final fileName in entry.value) {
          final fullPath = prefix.isEmpty ? fileName : '$prefix/$fileName';
          if (dirSet.contains(fullPath)) {
            dirs.add(fullPath);
          } else {
            files.add(fileName);
          }
        }
      } else if (dirPath.startsWith(prefix) && prefix.length < dirPath.length) {
        final rest = dirPath.substring(prefix.isEmpty ? 0 : prefix.length + 1);
        if (!rest.contains('/')) {
          dirs.add(dirPath);
        }
      }
    }

    for (final dirPath in (dirs.toList()..sort())) {
      final dirName = dirPath.contains('/') ? dirPath.split('/').last : dirPath;
      final children =
          _buildTreeNodes(lookup, dirPath, dirSet, sizeMap, absPathMap);
      result.add(FileTreeNode(
        name: dirName,
        relativePath: dirPath,
        isDir: true,
        children: children,
      ));
    }

    for (final fileName in (files..sort())) {
      final relPath = prefix.isEmpty ? fileName : '$prefix/$fileName';
      result.add(FileTreeNode(
        name: fileName,
        relativePath: relPath,
        fullPath: absPathMap[relPath],
        size: sizeMap[relPath] ?? 0,
      ));
    }

    return result;
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

// ---------------------------------------------------------------------------
// Bottom bar
// ---------------------------------------------------------------------------

class _BottomBar extends StatelessWidget {
  final int fileCount;
  final bool sending;
  final VoidCallback? onSend;

  const _BottomBar({
    required this.fileCount,
    this.sending = false,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom + 8;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPad),
      child: Row(
        children: [
          Text(
            '$fileCount ${fileCount == 1 ? 'item' : 'items'} selected',
            style: const TextStyle(fontSize: 14),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: sending ? null : onSend,
            icon: sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.send, size: 18),
            label: Text(sending ? 'Sending...' : 'Send'),
          ),
        ],
      ),
    );
  }
}

/// A single-text-field alert dialog that owns its [TextEditingController] so
/// the controller outlives the route's exit animation. Disposing an external
/// controller as soon as `showDialog`'s future resolves (i.e. at
/// `Navigator.pop`) crashes the next rebuild of the still-fading-out `TextField`
/// ("A TextEditingController was used after being disposed") — the controller
/// must live until the route subtree is unmounted, which happens in this
/// State's `dispose()`.
class _TextEntryDialog extends StatefulWidget {
  const _TextEntryDialog({
    required this.title,
    required this.label,
    required this.hint,
    required this.submitLabel,
    required this.onSubmit,
    this.keyboardType,
    this.helper,
    this.notice,
  });

  final String title;
  final String label;
  final String hint;
  final String submitLabel;
  final TextInputType? keyboardType;

  /// Optional secondary line under the field (format guidance, defaults).
  final String? helper;

  /// Optional block rendered above the field. Used to say *who* is on the
  /// other end before asking for anything from them.
  final Widget? notice;

  /// Runs the value the user typed. Returning `(ok: true)` pops the dialog;
  /// throwing pops with an error record the caller shows.
  final Future<({String value, bool ok, String? error})> Function(String value)
      onSubmit;

  @override
  State<_TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<_TextEntryDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    try {
      final result = await widget.onSubmit(value);
      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context, (value: value, ok: false, error: e.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.notice case final notice?) ...[
            notice,
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.hint,
              helperText: widget.helper,
              helperMaxLines: 3,
            ),
            keyboardType: widget.keyboardType,
            autofocus: true,
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.submitLabel)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Who answered
// ---------------------------------------------------------------------------

/// A fingerprint trimmed to head and tail — `89507b08…e0a0` — so it can be
/// compared against the Known Devices list and still fits one line of a
/// dialog. [shortFingerprint] (utils/format.dart) keeps the first 16 instead;
/// this one deliberately keeps *both* ends, because the answerer's last
/// characters are what distinguish it from a device paired under a similar
/// prefix. A fingerprint too short to trim is shown whole rather than mangled.
String fingerprintHeadTail(String fingerprint) {
  const head = 8;
  const tail = 4;
  if (fingerprint.length <= head + tail) return fingerprint;
  return '${fingerprint.substring(0, head)}…'
      '${fingerprint.substring(fingerprint.length - tail)}';
}

/// The sentence shown before a pairing code is asked for, naming the device
/// that answered the dialled address.
///
/// This exists because a code prompt on its own is a blind end: it asks the
/// user to trust an exchange while telling them nothing about what is on the
/// other end, so a device that *is* already known — paired elsewhere, on
/// another network, at an address this one has never recorded — is
/// indistinguishable from a stranger, and the user has no way to tell "this is
/// a different identity" apart from "the fix did not work". Naming the device
/// and showing enough of its fingerprint makes both readings checkable against
/// the Known Devices list before any code is entered.
String describeUnpairedAnswerer({
  required String name,
  required String address,
  String? fingerprint,
}) {
  final who = (fingerprint == null || fingerprint.isEmpty)
      ? name
      : '$name (${fingerprintHeadTail(fingerprint)})';
  return '$who answered at $address but is not paired with this device.';
}

/// Renders [describeUnpairedAnswerer]'s sentence above the pairing-code field.
class _AnswererNotice extends StatelessWidget {
  const _AnswererNotice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
    );
  }
}
