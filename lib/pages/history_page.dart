import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../models/file_tree.dart';
import '../providers/history.dart';
import '../providers/send_preparation.dart';
import '../services/android/content_uri_helper.dart' show ContentUriChannel;
import '../services/android/original_ref_store.dart';
import '../services/file_availability.dart';
import '../services/ipc/dto.dart';
import '../state/daemon_state.dart';
import '../widgets/file_tree_view.dart';
import 'send_preparation_page.dart';

class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(transferHistoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          if (records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () =>
                  ref.read(transferHistoryProvider.notifier).refresh(),
            ),
        ],
      ),
      body: records.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No transfer history yet',
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: () =>
                  ref.read(transferHistoryProvider.notifier).refresh(),
              child: ListView.builder(
                itemCount: records.length,
                // Key each tile by its transfer id so ListView never recycles a
                // tile's State onto a different record. Without this, a refresh
                // (fires after every terminal transfer event) re-uses the State
                // at each index, and a tile can keep the cached detail — and the
                // expanded state — of whatever record sat there before, so the
                // first tile shows another transfer's files.
                itemBuilder: (_, i) => _HistoryRecordTile(
                  key: ValueKey(records[i].transferId),
                  record: records[i],
                ),
              ),
            ),
    );
  }
}

class _HistoryRecordTile extends ConsumerStatefulWidget {
  final HistoryEntryDto record;

  const _HistoryRecordTile({super.key, required this.record});

  @override
  ConsumerState<_HistoryRecordTile> createState() => _HistoryRecordTileState();
}

class _HistoryRecordTileState extends ConsumerState<_HistoryRecordTile> {
  Future<HistoryDetailDto>? _detailFuture;
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _HistoryRecordTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Never serve a detail fetched for a different record. The ValueKey on the
    // tile normally gives each record a fresh State, but guard against the tile
    // being re-bound to another transfer id anyway: drop the stale cache and,
    // if the tile is currently expanded, refetch for the current record.
    if (oldWidget.record.transferId != widget.record.transferId) {
      _detailFuture = null;
      if (_expanded) {
        _detailFuture = ref
            .read(transferHistoryProvider.notifier)
            .detail(widget.record.transferId);
      }
    }
  }

  /// Fetch the per-record file detail lazily when the tile is expanded.
  void _ensureDetail(bool expanded) {
    _expanded = expanded;
    if (expanded && _detailFuture == null) {
      _detailFuture = ref
          .read(transferHistoryProvider.notifier)
          .detail(widget.record.transferId);
      // The FutureBuilder sits inside ExpansionTile.children, which is built
      // from the _detailFuture value captured in build(). Without a rebuild
      // here the FutureBuilder stays on `future: null` (nothing rendered) until
      // some unrelated list refresh happens to rebuild the tile.
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final theme = Theme.of(context);
    final isReceive = record.direction == 'receive';
    final isFailed = record.status == 'failed';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ExpansionTile(
        leading: Icon(
          isReceive ? Icons.arrow_downward : Icons.arrow_upward,
          color:
              isFailed ? Colors.red : (isReceive ? Colors.blue : Colors.orange),
        ),
        title: Text(
          record.peerName ?? 'Unknown device',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _stateBadge(record.status, theme),
                const Spacer(),
                Text(
                  '${_fileCountText(record.fileCount)} · ${_formatSize(record.totalBytes)}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                _formatTime(record.finishedTs),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ],
        ),
        onExpansionChanged: _ensureDetail,
        children: [
          _DetailSection(
              future: _detailFuture, onOpen: _openFile, onOpenRef: _openRef),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _resend(context, ref),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(isReceive ? 'Forward' : 'Resend'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _delete(context, ref),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Delete'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete record?'),
        content: const Text('This removes the transfer from history.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref
          .read(transferHistoryProvider.notifier)
          .delete(widget.record.transferId);
    }
  }

  Future<void> _openFile(String path) async {
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done && mounted) {
      _showOpenError(result.message);
    }
  }

  /// Opens the file the user actually handed us, addressed by its original
  /// reference rather than by the staging copy the daemon recorded.
  ///
  /// A `content://` document has no filesystem path, so it goes to the system
  /// viewer through the platform channel; a real-path original is opened by
  /// path exactly like a received file. A provider that refuses the grant is
  /// reported, never silently swallowed.
  Future<void> _openRef(OriginalRef ref) async {
    if (!ref.isContentUri) {
      final path = ref.asPath;
      if (path != null && path.isNotEmpty) {
        await _openFile(path);
        return;
      }
      _showOpenError('no usable path for this file');
      return;
    }
    // A provider that throws is as much a refusal as one that returns false:
    // either way the user gets told, instead of a button that did nothing.
    bool opened;
    try {
      opened = await ContentUriChannel.open(ref.value);
    } catch (e) {
      if (mounted) _showOpenError('$e');
      return;
    }
    if (!opened && mounted) {
      _showOpenError('no app could open this document');
    }
  }

  void _showOpenError(String reason) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open file: $reason')),
    );
  }

  Future<void> _resend(BuildContext context, WidgetRef ref) async {
    final record = widget.record;
    // A partial send resumes in place: `resume_send` (IPC resume_transfer)
    // reuses the same transfer id, so the receiver still holds the partial
    // bytes under it and skips already-received chunks instead of
    // re-transmitting from zero. Only other cases re-open the preparation page.
    if (record.direction == 'send' && record.status == 'partial') {
      final service = ref.read(daemonStateProvider).service;
      if (service == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Daemon not running')));
        }
        return;
      }
      try {
        await service.resumeTransfer(record.transferId);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not resume: $e')));
        }
      }
      return;
    }
    // Other directions/statuses re-open the send-preparation page with the
    // original files and recipient pre-loaded, so the user can re-target the
    // transfer, edit the file set, or drop stale files before sending again.
    final detail =
        await ref.read(transferHistoryProvider.notifier).detail(record.transferId);
    final entries = <SendFileEntry>[];
    for (final f in detail.files) {
      final abs = f.absolutePath;
      if (abs != null && File(abs).existsSync()) {
        entries.add(SendFileEntry(
            path: abs, relativePath: f.relativePath, size: f.size));
      }
    }
    if (!context.mounted) return;
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Files not found on disk')));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => SendPreparationPage(
                initialEntries: entries,
                initialPeerFingerprint: record.peerDeviceFingerprint,
                initialPeerName: record.peerName,
              )),
    );
  }

  Widget _stateBadge(String status, ThemeData theme) {
    final (icon, color, label) = switch (status) {
      'completed' => (Icons.check_circle, Colors.green, 'Completed'),
      'failed' => (Icons.error, Colors.red, 'Failed'),
      'cancelled' => (Icons.cancel, Colors.grey, 'Cancelled'),
      'rejected' => (Icons.block, Colors.orange, 'Rejected'),
      'partial' => (Icons.warning_amber, Colors.amber, 'Partial'),
      _ => (Icons.circle, Colors.grey, status),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }

  String _fileCountText(int count) =>
      '$count ${count == 1 ? 'file' : 'files'}';

  String _formatTime(int? ts) {
    if (ts == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _DetailSection extends StatelessWidget {
  final Future<HistoryDetailDto>? future;
  final Future<void> Function(String path) onOpen;
  final Future<void> Function(OriginalRef ref) onOpenRef;

  const _DetailSection({
    required this.future,
    required this.onOpen,
    required this.onOpenRef,
  });

  @override
  Widget build(BuildContext context) {
    final future = this.future;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<HistoryDetailDto>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Could not load details: ${snapshot.error}',
                style: const TextStyle(fontSize: 12, color: Colors.red)),
          );
        }
        final detail = snapshot.data!;
        final nodes = buildFileTreeFromHistoryFiles(detail.files);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _HistoryFileTree(
              nodes: nodes, onOpen: onOpen, onOpenRef: onOpenRef),
        );
      },
    );
  }
}

/// Renders a finished transfer's file tree, first resolving each file's
/// availability from its *original* reference.
///
/// The staged copy the daemon recorded is a one-shot artifact that the send
/// cache deletes by design, so judging reachability by that path alone made
/// every sent file read "File not accessible" once it was cleaned up. This
/// widget asks about the file the user actually chose, then hands the verdict
/// to [FileTreeView] so the rendering stays synchronous.
class _HistoryFileTree extends StatefulWidget {
  final List<FileTreeNode> nodes;
  final Future<void> Function(String path) onOpen;
  final Future<void> Function(OriginalRef ref) onOpenRef;

  const _HistoryFileTree({
    required this.nodes,
    required this.onOpen,
    required this.onOpenRef,
  });

  @override
  State<_HistoryFileTree> createState() => _HistoryFileTreeState();
}

class _HistoryFileTreeState extends State<_HistoryFileTree> {
  late Future<Map<String, _FileVerdict>> _verdicts;

  @override
  void initState() {
    super.initState();
    _verdicts = _resolve();
  }

  @override
  void didUpdateWidget(covariant _HistoryFileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The detail FutureBuilder can hand us a different record's tree; never
    // show the previous record's verdicts against new nodes.
    if (!identical(oldWidget.nodes, widget.nodes)) {
      _verdicts = _resolve();
    }
  }

  /// Resolves every leaf path in the tree. Failures resolve to "not accessible"
  /// rather than propagating, so one bad row can't blank the whole list.
  ///
  /// The original reference rides along with the verdict because it is the
  /// thing "open" must target: the recorded path may be a staging copy the
  /// send cache has already deleted, while the reference still points at the
  /// user's own file.
  Future<Map<String, _FileVerdict>> _resolve() async {
    final paths = <String>{};
    void walk(FileTreeNode node) {
      if (node.isDir) {
        node.children.forEach(walk);
      } else if (node.fullPath != null) {
        paths.add(node.fullPath!);
      }
    }

    widget.nodes.forEach(walk);

    final entries = await Future.wait(paths.map((path) async {
      try {
        final ref = await OriginalRefStore.lookup(path);
        final availability = await FileAvailabilityResolver.resolve(
          originalRef: ref?.value,
          stagedPath: path,
        );
        return MapEntry(
            path, _FileVerdict(availability: availability, ref: ref));
      } catch (_) {
        return MapEntry(path,
            const _FileVerdict(availability: FileAvailability.inaccessible));
      }
    }));
    return Map<String, _FileVerdict>.fromEntries(entries);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, _FileVerdict>>(
      future: _verdicts,
      builder: (context, snapshot) {
        // Until verdicts land, fall back to the pre-existing exists-on-disk
        // rendering rather than flashing "not accessible" at a file that may
        // well be reachable.
        final data = snapshot.data;
        Map<String, FileAvailability>? availability;
        Map<String, OriginalRef>? openRefByPath;
        if (data != null) {
          availability = {
            for (final entry in data.entries) entry.key: entry.value.availability,
          };
          final refs = <String, OriginalRef>{};
          for (final entry in data.entries) {
            final ref = entry.value.ref;
            if (ref != null) refs[entry.key] = ref;
          }
          openRefByPath = refs;
        }
        return FileTreeView(
          nodes: widget.nodes,
          onOpenFile: widget.onOpen,
          onOpenRef: widget.onOpenRef,
          formatSize: _formatSize,
          availabilityByPath: availability,
          openRefByPath: openRefByPath,
        );
      },
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// What history resolved about one recorded file: whether the user's file is
/// still reachable, and the original reference to reach it through.
class _FileVerdict {
  final FileAvailability availability;

  /// The file the user actually handed us, when one was recorded for this
  /// staging path. Null for a received file (the recorded path *is* the file)
  /// or for a row written before original references were kept.
  final OriginalRef? ref;

  const _FileVerdict({required this.availability, this.ref});
}
