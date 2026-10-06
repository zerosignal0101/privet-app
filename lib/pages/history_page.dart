import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../models/file_tree.dart';
import '../providers/history.dart';
import '../providers/send_preparation.dart';
import '../services/android/content_uri_helper.dart' show ContentUriChannel;
import '../services/android/original_ref_store.dart';
import '../services/android/resend_staging.dart';
import '../services/file_availability.dart';
import '../services/ipc/dto.dart';
import '../services/privet_service.dart';
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
      await _resumePartial(context, ref);
      return;
    }
    // Other directions/statuses re-open the send-preparation page with the
    // original files and recipient pre-loaded, so the user can re-target the
    // transfer, edit the file set, or drop stale files before sending again.
    final detail =
        await ref.read(transferHistoryProvider.notifier).detail(record.transferId);
    final sources = detail.files
        .map((f) => ResendSource(
              absolutePath: f.absolutePath,
              relativePath: f.relativePath,
              size: f.size,
            ))
        .toList();

    // The recorded `absolute_path` of an Android send is a staging copy the send
    // cache deletes once the transfer is terminal, so it is normally gone by now.
    // Resolve each file from its *original reference* into a path that exists
    // right now, and report the ones that cannot be resolved instead of letting
    // the daemon fail on a path that no longer exists (which surfaces as a bare
    // "Transfer Failed io").
    final stager = ResendStager();

    // A send that came from a picked FOLDER is re-staged as a whole tree and
    // re-opened as ONE entry, not one entry per file. Resolving each recorded
    // file separately and handing the page a flat list is what a "resend this
    // folder" must not do: the preparation page expands a directory entry by
    // walking it, so a flat per-file list would both lose the nesting and send
    // the files as N independent roots.
    final treeRoot = await stager.treeRootOf(sources);
    if (!context.mounted) return;
    if (treeRoot != null) {
      final restaged = await stager.restageTreeRoot(treeRoot);
      if (!context.mounted) return;
      if (!restaged.isSendable) {
        _showResendBlocked([
          ResendCandidate(
            label: detail.rootName ?? 'folder',
            size: 0,
            reason: restaged.reason,
          ),
        ]);
        return;
      }
      final root = restaged.rootPath!;
      // Guarded by the stager; re-checked so a URI can never reach the page that
      // hands paths to the daemon.
      assertSendablePath(root);
      _openPreparation(
        context,
        record,
        // A directory entry, so the page walks the tree it is given and shows
        // the same hierarchy the user picked.
        <SendFileEntry>[SendFileEntry(
          path: root,
          relativePath: detail.rootName ?? _basename(root),
          isDir: true,
        )],
      );
      return;
    }

    final candidates = await stager.plan(sources);
    if (!context.mounted) return;

    final sendable = candidates.where((c) => c.isSendable).toList();
    final blocked = candidates.where((c) => !c.isSendable).toList();
    if (sendable.isEmpty) {
      // Nothing can be resent: say exactly why, per file. No transfer request is
      // made, so this can never turn into a failed transfer.
      _showResendBlocked(blocked);
      return;
    }

    final entries = <SendFileEntry>[];
    for (final c in sendable) {
      final path = c.path!;
      // Guarded by the stager; re-checked here so a URI can never reach the
      // page that hands paths to the daemon.
      assertSendablePath(path);
      entries.add(
          SendFileEntry(path: path, relativePath: c.label, size: c.size));
    }
    _openPreparation(context, record, entries);
    if (blocked.isEmpty) return;
    // Some files made it and some did not: carry the specific reasons into the
    // prepare page's one-time notice rather than dropping them silently.
    final message = _blockedSummary(blocked);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  /// Opens the send-preparation page for [record] with [entries] pre-loaded.
  ///
  /// Both re-open paths (the finished-send resend and the tree-rooted variant)
  /// land here, so the recipient pre-fill and the page's shape are decided once.
  void _openPreparation(
    BuildContext context,
    HistoryEntryDto record,
    List<SendFileEntry> entries,
  ) {
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

  /// The last path segment of [path], or the whole path when it has none.
  ///
  /// Used to name a re-staged tree when the history row recorded no
  /// `root_name`; never dereferenced, so a path it cannot split is returned
  /// unchanged rather than throwing.
  String _basename(String path) {
    final norm = path.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    if (idx < 0 || idx == norm.length - 1) return path;
    return norm.substring(idx + 1);
  }

  /// Resumes a partial send in place.
  ///
  /// A resume reuses the SAME transfer id, so the receiver keeps the chunks it
  /// has already verified — that is the whole point of resuming rather than
  /// resending.
  ///
  /// The daemon rebuilds its file list from the source paths it recorded. Two
  /// things can make those paths unusable, and only one of them needs work:
  ///
  /// - **A send rooted at a DIRECTORY** (the app supports it: a folder pick
  ///   caches a tree and the engine recurses it in `prepare_paths`) recorded
  ///   NESTED relative paths — `sub/a.txt`, `b.txt`. Resolving each of those
  ///   through [ResendStager] and sending the results as an override is
  ///   actively wrong: an override is a list of individual paths, so
  ///   `prepare_paths` derives `relative_path = file_name` for each and the
  ///   set comes back flat — `a.txt`, `b.txt` — which
  ///   `check_override_matches_intent` then refuses. When every recorded path
  ///   is still there the fix is to build NO override at all: the engine re-reads
  ///   the recorded paths and reproduces exactly the nesting, and nothing is
  ///   re-staged.
  /// - **A send whose sources are gone.** For an Android file pick every source
  ///   is a staging copy that `send_cache.dart` deletes when the transfer
  ///   reaches a terminal state (cancellation included), while the history row
  ///   keeps pointing at it. Resuming from those paths fails as a bare `io`
  ///   error that names neither the file nor the cause, so the sources are
  ///   re-resolved from their *original reference* — the `content://` document
  ///   the user picked, or a real path — and sent as the override.
  ///
  /// Both branches keep the same invariant: a resume covers the whole recorded
  /// file set or nothing is sent at all.
  Future<void> _resumePartial(BuildContext context, WidgetRef ref) async {
    final record = widget.record;
    final service = ref.read(daemonStateProvider).service;
    if (service == null) {
      _showSnack('Daemon not running');
      return;
    }
    final detail =
        await ref.read(transferHistoryProvider.notifier).detail(record.transferId);
    final sources = detail.files
        .map((f) => ResendSource(
              absolutePath: f.absolutePath,
              relativePath: f.relativePath,
              size: f.size,
            ))
        .toList();

    // Prefer the recorded paths when they are all still there: no override is
    // built, so the engine reads the intent itself and the file set — including
    // any nesting from a directory-rooted send — is reproduced exactly.
    //
    // `typeSync` and not `File(p).existsSync()`, because a send can be rooted at
    // a directory and `File(p).existsSync()` is false for one. That mistake is
    // what made this branch miss directory-rooted sends in the first place.
    if (!context.mounted) return;
    if (_allRecordedPathsPresent(sources)) {
      await _issueResume(context, service, record.transferId, paths: null);
      return;
    }

    // Some recorded path is gone.
    final stager = ResendStager();

    // A send that came from a picked FOLDER is re-staged as a whole tree, and
    // resumed with the new root as the single override. Not because the
    // per-file path is merely incomplete for a folder, but because it is wrong:
    // an override is a list of individual paths, so the engine derives
    // `relative_path = file_name` for each and the nested set comes back flat,
    // which `check_override_matches_intent` refuses. One directory override is
    // recursed by `prepare_paths`, so the hierarchy survives.
    final treeRoot = await stager.treeRootOf(sources);
    if (!context.mounted) return;
    if (treeRoot != null) {
      final restaged = await stager.restageTreeRoot(treeRoot);
      if (!context.mounted) return;
      if (!restaged.isSendable) {
        _showSnack('Cannot resume — ${restaged.reason}\n'
            'Nothing was sent. This send was interrupted and its temporary copy '
            'was cleaned up; pick the folder again to resume it.');
        return;
      }
      final root = restaged.rootPath!;
      // Guarded by the stager; re-checked so a `content://` string can never
      // reach the daemon.
      assertSendablePath(root);
      // Registered the same way per-file copies are, so the fresh tree is
      // deleted on THIS transfer's terminal event rather than leaking.
      await ref
          .read(sendPreparationProvider.notifier)
          .trackTempPathsFor(record.transferId, [root]);
      if (!context.mounted) return;
      await _issueResume(context, service, record.transferId, paths: [root]);
      return;
    }

    // No tree reference: fall back to resolving every file from its original
    // reference with the same `ResendStager` the finished-transfer resend uses.
    // This stays the honest, per-file failure when the send was a multi-file
    // pick whose sources are gone.
    final candidates = await stager.plan(sources);
    if (!context.mounted) return;

    final blocked = candidates.where((c) => !c.isSendable).toList();
    if (blocked.isNotEmpty) {
      // Refuse up front: resuming a subset would leave the receiver's partial
      // state describing files that never arrive.
      final reasons = blocked
          .map((c) => c.reason ?? '${c.label}: unavailable')
          .join('\n');
      _showSnack('Cannot resume — $reasons\n'
          'Nothing was sent. This send was interrupted and its temporary copy '
          'was cleaned up; pick the file again to resume it.');
      return;
    }

    final paths = <String>[];
    for (final c in candidates) {
      final path = c.path!;
      // Guarded by the stager; re-checked so a `content://` string can never
      // reach the daemon.
      assertSendablePath(path);
      paths.add(path);
    }

    // The fresh copies belong to THIS transfer id, so the existing terminal-state
    // cleanup frees them exactly like the ones the original send registered —
    // adopted, not leaked.
    await ref
        .read(sendPreparationProvider.notifier)
        .trackTempPathsFor(record.transferId, paths);
    if (!context.mounted) return;

    await _issueResume(context, service, record.transferId, paths: paths);
  }

  /// Whether every recorded source is still on disk.
  ///
  /// All-or-nothing on purpose: a partial answer is not usable, because a
  /// resume that overrides only some of the files would describe a different
  /// file set than the receiver already holds. When this is false the caller
  /// falls back to re-resolving the whole set through [ResendStager].
  ///
  /// A recorded path that is null or empty counts as gone: there is nothing to
  /// hand the engine.
  bool _allRecordedPathsPresent(List<ResendSource> sources) =>
      sources.isNotEmpty &&
      sources.every((s) {
        final p = s.absolutePath;
        if (p == null || p.isEmpty) return false;
        try {
          return FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound;
        } catch (_) {
          // A path that cannot even be stat'd (permissions, a broken mount) is
          // not a path we can promise the daemon will read. Let the stager try.
          return false;
        }
      });

  /// Issues the resume itself, with [paths] as the source override or null for
  /// "use the recorded paths", and reports a failure rather than throwing.
  Future<void> _issueResume(
    BuildContext context,
    PrivetService service,
    String transferId, {
    required List<String>? paths,
  }) async {
    try {
      await service.resumeTransfer(transferId, paths: paths);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not resume: $e')));
      }
    }
  }

  /// Explains, per file, why nothing could be resent. Deliberately specific:
  /// naming the file and the cause is the difference between a user who knows
  /// what to do and a user filing the same "io" report again.
  void _showResendBlocked(List<ResendCandidate> blocked) {
    final reasons = blocked.map((c) => c.reason ?? '${c.label}: unavailable').join('\n');
    _showSnack('Nothing to resend — $reasons');
  }

  String _blockedSummary(List<ResendCandidate> blocked) {
    if (blocked.length == 1) return 'Left out: ${blocked.first.reason}';
    return 'Left out ${blocked.length} files — first: ${blocked.first.reason}';
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
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
