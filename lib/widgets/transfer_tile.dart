import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/transfers.dart';

/// Unified transfer tile for all states: preparing/offered, awaiting-accept,
/// transferring, paused, completed, failed, cancelled. Actions (accept/reject/
/// pause/resume/cancel) talk to `activeTransfersProvider`; the daemon's
/// authoritative record lives in the history provider.
class TransferTile extends ConsumerStatefulWidget {
  final ActiveTransfer transfer;

  const TransferTile({super.key, required this.transfer});

  @override
  ConsumerState<TransferTile> createState() => _TransferTileState();
}

class _TransferTileState extends ConsumerState<TransferTile> {
  int _countdown = -1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _maybeStartCountdown();
  }

  @override
  void didUpdateWidget(TransferTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When a different transfer reuses this widget slot (the list is keyed by
    // transferId, so this only fires defensively), discard any leftover
    // countdown so the new transfer gets its own full 5s window.
    if (widget.transfer.transferId != oldWidget.transfer.transferId) {
      _timer?.cancel();
      _countdown = -1;
    }
    _maybeStartCountdown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _maybeStartCountdown() {
    if (_countdown == -1 &&
        (widget.transfer.state == TransferState.completed ||
            widget.transfer.state == TransferState.failed ||
            widget.transfer.state == TransferState.cancelled)) {
      _startCountdown();
    }
  }

  /// Terminal tiles show a 5s countdown, then drop out of the live list.
  void _startCountdown() {
    _timer?.cancel();
    setState(() => _countdown = 5);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_countdown <= 1) {
        t.cancel();
        setState(() => _countdown = 0);
        ref
            .read(activeTransfersProvider.notifier)
            .remove(widget.transfer.transferId);
      } else {
        setState(() => _countdown -= 1);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.transfer;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: _buildContent(context, t),
    );
  }

  Widget _buildContent(BuildContext context, ActiveTransfer t) {
    final theme = Theme.of(context);
    switch (t.state) {
      case TransferState.preparing:
      case TransferState.offered:
        return t.isAwaitingAccept ? _buildAwaitingAccept(t) : _buildNegotiating(t);
      case TransferState.reconnecting:
        return _buildNegotiating(t, label: 'Reconnecting...');
      case TransferState.transferring:
      case TransferState.paused:
        return _buildProgress(t, theme);
      case TransferState.completed:
        return _buildCompleted(t, theme);
      case TransferState.failed:
        return _buildFailed(t, theme);
      case TransferState.cancelled:
        return _buildCancelled(t);
    }
  }

  Widget _buildNegotiating(ActiveTransfer t, {String label = 'Connecting...'}) {
    return ListTile(
      leading: const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      title: Text('${_directionIcon(t.direction)} $label'),
      subtitle: Text(t.peerName ?? 'Unknown'),
      trailing: IconButton(
        icon: const Icon(Icons.stop_circle_outlined, color: Colors.red),
        tooltip: 'Cancel',
        onPressed: () =>
            ref.read(activeTransfersProvider.notifier).cancel(t.transferId),
      ),
    );
  }

  Widget _buildAwaitingAccept(ActiveTransfer t) {
    final files = t.fileCount;
    return ListTile(
      leading: const Icon(Icons.help_outline, color: Colors.orange),
      title: Text('Accept transfer${files > 0 ? ' ($files files)' : ''}?'),
      subtitle: Text(_formatSize(t.totalBytes)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.red),
            tooltip: 'Reject',
            onPressed: () async {
              final error = await ref
                  .read(activeTransfersProvider.notifier)
                  .reject(t.transferId);
              if (error != null && mounted) _showActionError(error);
            },
          ),
          IconButton(
            icon: const Icon(Icons.check, color: Colors.green),
            tooltip: 'Accept',
            onPressed: () async {
              final error = await ref
                  .read(activeTransfersProvider.notifier)
                  .accept(t.transferId);
              if (error != null && mounted) _showActionError(error);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildProgress(ActiveTransfer t, ThemeData theme) {
    final percent = (t.fraction * 100).clamp(0.0, 100.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(_directionIcon(t.direction),
                  style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.peerName ?? 'Transfer',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              Text(
                '${percent.toStringAsFixed(1)}%',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              if (t.state == TransferState.paused)
                IconButton(
                  icon: const Icon(Icons.play_arrow, size: 20, color: Colors.green),
                  tooltip: 'Resume',
                  onPressed: () =>
                      ref.read(activeTransfersProvider.notifier).resume(t.transferId),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              IconButton(
                icon: const Icon(Icons.stop_circle_outlined,
                    size: 20, color: Colors.red),
                tooltip: 'Cancel transfer',
                onPressed: () =>
                    ref.read(activeTransfersProvider.notifier).cancel(t.transferId),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: percent / 100,
            backgroundColor: Colors.grey.shade200,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                t.state == TransferState.paused ? 'Paused' : _directionIcon(t.direction),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const Spacer(),
              Text(
                '${_formatBytes(t.verifiedBytes)} / ${_formatBytes(t.totalBytes)}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCompleted(ActiveTransfer t, ThemeData theme) {
    return ListTile(
      leading: const Icon(Icons.check_circle, color: Colors.green),
      title: const Text('Transfer complete'),
      subtitle: Text(t.peerName ?? ''),
      trailing: _countdown > 0
          ? Text('$_countdown', style: TextStyle(color: Colors.grey.shade500))
          : null,
    );
  }

  Widget _buildFailed(ActiveTransfer t, ThemeData theme) {
    return ListTile(
      leading: const Icon(Icons.error, color: Colors.red),
      title: const Text('Transfer failed'),
      subtitle: Text(_friendlyError(t.errorCode, t.peerName)),
      trailing: _countdown > 0
          ? Text('$_countdown', style: TextStyle(color: Colors.grey.shade500))
          : null,
    );
  }

  /// Turns the daemon's error code into a readable message. The trust-related
  /// codes tell the user *why* the transfer failed and what to do (re-pair)
  /// instead of a bare "transfer"/"rejected" with no guidance.
  String _friendlyError(String? code, String? peerName) {
    if (code == null || code.isEmpty) return peerName ?? '';
    return switch (code) {
      'rejected' || 'peer_not_trusted' =>
        'Peer no longer trusts you — pair again to send',
      'revoked' => 'Peer revoked you — pair again',
      'key_mismatch' => 'Peer key changed — pair again',
      'not_paired' => 'Not paired with this device — pair first',
      'transport_lost' || 'transport' =>
        'Connection lost — is the other device online?',
      'declined' => 'Peer declined the transfer',
      _ => code,
    };
  }

  Widget _buildCancelled(ActiveTransfer t) {
    return ListTile(
      leading: const Icon(Icons.cancel, color: Colors.grey),
      title: const Text('Transfer cancelled'),
      subtitle: Text(t.peerName ?? ''),
      trailing: _countdown > 0
          ? Text('$_countdown', style: TextStyle(color: Colors.grey.shade500))
          : null,
    );
  }

  void _showActionError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _directionIcon(String direction) => direction == 'send' ? '↑' : '↓';

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
