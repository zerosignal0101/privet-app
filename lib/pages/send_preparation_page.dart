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
    this.initialFilePaths,
    this.initialEntries,
  });

  final String? initialPeerFingerprint;
  final String? initialPeerName;

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
    final trustedFps =
        (trusted.value ?? const []).map((t) => t.deviceFingerprint).toSet();
    final needsPairing = state.peerFingerprint != null &&
        !trustedFps.contains(state.peerFingerprint);
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
                    '${state.peerName ?? 'This device'} is offline — turn it on '
                    'or choose another recipient.',
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
      onPairByAddress: () => _pairByAddress(context, ref),
    );
  }

  /// Pair-by-address flow: ask for an IP (port optional), then the code the
  /// remote device is displaying, then `pair(ip, quicPort, tcpPort, code)`.
  ///
  /// This is the manual counterpart to discovery, for networks where beacons
  /// don't get through (AP client isolation). The address the other device's
  /// "This Machine" section copies is exactly what is accepted here.
  Future<void> _pairByAddress(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<({String? value, bool ok, String? error})>(
      context: context,
      builder: (ctx) => _TextEntryDialog(
        title: 'Pair by Address',
        label: 'IP:Port',
        hint: '10.29.210.120  (port optional)',
        helper: 'Port is optional — omit it to use $kDefaultPort. '
            'IPv6 looks like [fe80::1]:$kDefaultPort',
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

    final service = ref.read(daemonStateProvider).service;
    if (service == null) return;
    final ok = await _enterTheirCode(
      title: 'Enter Pairing Code',
      onPair: (code) => service.pair(
          ip: parsed.ip,
          quicPort: parsed.port,
          tcpPort: parsed.port,
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
    required Future<dynamic> Function(String code) onPair,
  }) async {
    final result = await showDialog<({String? value, bool ok, String? error})>(
      context: context,
      builder: (ctx) => _TextEntryDialog(
        title: title,
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
    if (fp != null && !onlineFps.contains(fp)) {
      ref.read(sendPreparationProvider.notifier).setError(
            '${s.peerName ?? 'The selected device'} is offline — it can\'t '
            'receive files right now. Make sure it is running and on the same '
            'network, then try again.',
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
  });

  final String title;
  final String label;
  final String hint;
  final String submitLabel;
  final TextInputType? keyboardType;

  /// Optional secondary line under the field (format guidance, defaults).
  final String? helper;

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
      content: TextField(
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
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.submitLabel)),
      ],
    );
  }
}
