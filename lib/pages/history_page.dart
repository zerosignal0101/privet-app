import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../models/file_tree.dart';
import '../providers/history.dart';
import '../services/ipc/dto.dart';
import '../widgets/file_tree_view.dart';

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
                itemBuilder: (_, i) => _HistoryRecordTile(record: records[i]),
              ),
            ),
    );
  }
}

class _HistoryRecordTile extends ConsumerStatefulWidget {
  final HistoryEntryDto record;

  const _HistoryRecordTile({required this.record});

  @override
  ConsumerState<_HistoryRecordTile> createState() => _HistoryRecordTileState();
}

class _HistoryRecordTileState extends ConsumerState<_HistoryRecordTile> {
  Future<HistoryDetailDto>? _detailFuture;

  /// Fetch the per-record file detail lazily when the tile is expanded.
  void _ensureDetail(bool expanded) {
    if (expanded && _detailFuture == null) {
      _detailFuture = ref
          .read(transferHistoryProvider.notifier)
          .detail(widget.record.transferId);
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
          _DetailSection(future: _detailFuture, onOpen: _openFile),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open file: ${result.message}')),
      );
    }
  }

  Future<void> _resend(BuildContext context, WidgetRef ref) async {
    final record = widget.record;
    if (record.direction == 'receive') {
      // Forwarding received files to a different peer needs SendPreparationPage
      // (Plan 3 Task 9); until then, surface a message.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Forwarding not yet available')),
      );
      return;
    }
    final newId =
        await ref.read(transferHistoryProvider.notifier).resend(record.transferId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                newId.isNotEmpty ? 'Transfer re-queued' : 'Resend failed')),
      );
    }
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

  const _DetailSection({required this.future, required this.onOpen});

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
          child: FileTreeView(
            nodes: nodes,
            onOpenFile: onOpen,
            formatSize: _formatSize,
          ),
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
