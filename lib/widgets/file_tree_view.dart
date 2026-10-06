import 'dart:io';

import 'package:flutter/material.dart';

import '../models/file_tree.dart';
import '../services/file_availability.dart'
    show FileAvailability, stagedCopyCleanedMessage;

/// A reusable file tree widget that shows FileTreeNode recursively.
/// Used in send preparation (with remove buttons) and history (read-only).
class FileTreeView extends StatelessWidget {
  final List<FileTreeNode> nodes;
  final void Function(String relativePath)? onRemoveFile;
  final void Function(String fullPath)? onOpenFile;
  final bool showRemoveButtons;
  final String Function(int bytes)? formatSize;
  /// When true, always show the node's declared size instead of checking
  /// whether the file exists on disk (used for incoming transfers where
  /// files haven't been received yet).
  final bool showSizeOnly;

  /// Per-file reachability for history, keyed by the node's absolute path.
  ///
  /// Supplied by the history page, which resolves each file's *original*
  /// reference (see `FileAvailabilityResolver`) before building the tree.
  /// A node whose path is absent from the map keeps the plain
  /// exists-on-disk behaviour, so this stays optional for send preparation.
  final Map<String, FileAvailability>? availabilityByPath;

  const FileTreeView({
    super.key,
    this.nodes = const [],
    this.onRemoveFile,
    this.onOpenFile,
    this.showRemoveButtons = false,
    this.formatSize,
    this.showSizeOnly = false,
    this.availabilityByPath,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _buildNodeList(context, nodes, 0),
    );
  }

  List<Widget> _buildNodeList(
    BuildContext context,
    List<FileTreeNode> nodes,
    int depth,
  ) {
    final widgets = <Widget>[];
    for (final node in nodes) {
      widgets.add(_buildNode(context, node, depth));
    }
    return widgets;
  }

  Widget _buildNode(BuildContext context, FileTreeNode node, int depth) {
    if (node.isDir) {
      return _DirectoryNode(
        node: node,
        depth: depth,
        showRemoveButtons: showRemoveButtons,
        onRemoveFile: onRemoveFile,
        onOpenFile: onOpenFile,
        formatSize: formatSize,
        showSizeOnly: showSizeOnly,
        availabilityByPath: availabilityByPath,
      );
    }
    final exists = node.fullPath != null && File(node.fullPath!).existsSync();
    return _FileNode(
      node: node,
      depth: depth,
      showRemoveButton: showRemoveButtons,
      onRemove: onRemoveFile != null
          ? () => onRemoveFile!(node.relativePath)
          : null,
      // "Open" hands a real filesystem path to the system viewer, so it stays
      // gated on the file actually being there — a reachable original
      // reference does not make a deleted staging copy openable.
      onOpen: onOpenFile != null && node.fullPath != null && exists
          ? () => onOpenFile!(node.fullPath!)
          : null,
      availability: showSizeOnly
          ? FileAvailability.accessible
          : _availabilityFor(node, exists),
      formatSize: formatSize,
    );
  }

  /// The pre-resolved availability for [node], or null to fall back to the
  /// exists-on-disk behaviour used outside history.
  FileAvailability? _availabilityFor(FileTreeNode node, bool exists) {
    final path = node.fullPath;
    if (path == null) return exists ? FileAvailability.accessible : null;
    final resolved = availabilityByPath?[path];
    if (resolved != null) return resolved;
    return exists ? FileAvailability.accessible : FileAvailability.inaccessible;
  }
}

class _DirectoryNode extends StatefulWidget {
  final FileTreeNode node;
  final int depth;
  final bool showRemoveButtons;
  final void Function(String relativePath)? onRemoveFile;
  final void Function(String fullPath)? onOpenFile;
  final String Function(int bytes)? formatSize;
  final bool showSizeOnly;
  final Map<String, FileAvailability>? availabilityByPath;

  const _DirectoryNode({
    required this.node,
    required this.depth,
    required this.showRemoveButtons,
    this.onRemoveFile,
    this.onOpenFile,
    this.formatSize,
    this.showSizeOnly = false,
    this.availabilityByPath,
  });

  @override
  State<_DirectoryNode> createState() => _DirectoryNodeState();
}

class _DirectoryNodeState extends State<_DirectoryNode> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final sizeText = widget.formatSize != null
        ? widget.formatSize!(widget.node.totalSize)
        : _formatSize(widget.node.totalSize);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 16.0 * widget.depth),
          child: ListTile(
            dense: true,
            leading: Icon(
              _expanded ? Icons.folder_open : Icons.folder,
              size: 20,
              color: Colors.amber.shade600,
            ),
            title: Text(
              widget.node.name,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${widget.node.fileCount} files, $sizeText',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            trailing: widget.showRemoveButtons && widget.onRemoveFile != null
                ? IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => widget.onRemoveFile!(widget.node.relativePath),
                    tooltip: 'Remove folder',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  )
                : IconButton(
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
        ),
        if (_expanded)
          ..._buildChildren(context, widget.node.children, widget.depth + 1),
      ],
    );
  }

  /// Mirrors the parent widget's fallback: use the pre-resolved availability
  /// when history supplied one, else fall back to exists-on-disk.
  FileAvailability _childAvailability(FileTreeNode node, bool exists) {
    final path = node.fullPath;
    if (path == null) {
      return exists ? FileAvailability.accessible : FileAvailability.inaccessible;
    }
    return widget.availabilityByPath?[path] ??
        (exists ? FileAvailability.accessible : FileAvailability.inaccessible);
  }

  List<Widget> _buildChildren(
    BuildContext context,
    List<FileTreeNode> children,
    int depth,
  ) {
    final widgets = <Widget>[];
    for (final child in children) {
      if (child.isDir) {
        widgets.add(_DirectoryNode(
          node: child,
          depth: depth,
          showRemoveButtons: widget.showRemoveButtons,
          onRemoveFile: widget.onRemoveFile,
          onOpenFile: widget.onOpenFile,
          formatSize: widget.formatSize,
          showSizeOnly: widget.showSizeOnly,
          availabilityByPath: widget.availabilityByPath,
        ));
      } else {
        final exists = child.fullPath != null && File(child.fullPath!).existsSync();
        widgets.add(_FileNode(
          node: child,
          depth: depth,
          showRemoveButton: widget.showRemoveButtons,
          onRemove: widget.onRemoveFile != null
              ? () => widget.onRemoveFile!(child.relativePath)
              : null,
          onOpen: widget.onOpenFile != null && child.fullPath != null && exists
              ? () => widget.onOpenFile!(child.fullPath!)
              : null,
          availability: widget.showSizeOnly
              ? FileAvailability.accessible
              : _childAvailability(child, exists),
          formatSize: widget.formatSize,
        ));
      }
    }
    return widgets;
  }
}

class _FileNode extends StatelessWidget {
  final FileTreeNode node;
  final int depth;
  final bool showRemoveButton;
  final VoidCallback? onRemove;
  final VoidCallback? onOpen;

  /// Reachability of the file the user actually handed us. Null means "not
  /// resolved", which renders as unreachable — the pre-existing behaviour.
  final FileAvailability? availability;
  final String Function(int bytes)? formatSize;

  const _FileNode({
    required this.node,
    required this.depth,
    this.showRemoveButton = false,
    this.onRemove,
    this.onOpen,
    this.availability,
    this.formatSize,
  });

  @override
  Widget build(BuildContext context) {
    final sizeText = formatSize != null
        ? formatSize!(node.size)
        : _formatSize(node.size);
    final state = availability ?? FileAvailability.inaccessible;

    // Only a genuinely unreachable file is greyed out and called out in orange.
    // A cleaned staging copy is normal, expected behaviour, so it reads as an
    // ordinary note rather than an error — the user's file is fine.
    final missing = state == FileAvailability.inaccessible;
    final stagedCleaned = state == FileAvailability.stagedCopyCleaned;
    final icon = missing
        ? Icons.file_present
        : (stagedCleaned ? Icons.cleaning_services_outlined : Icons.insert_drive_file);
    final iconColor = missing ? Colors.grey : (stagedCleaned ? Colors.blueGrey : null);
    final subtitleText = missing
        ? 'File not accessible'
        : (stagedCleaned ? stagedCopyCleanedMessage : sizeText);
    final subtitleColor = missing
        ? Colors.orange
        : (stagedCleaned ? Colors.blueGrey.shade700 : Colors.grey.shade600);

    return Padding(
      padding: EdgeInsets.only(left: 16.0 * depth),
      child: ListTile(
        dense: true,
        leading: Icon(
          icon,
          size: 18,
          color: iconColor,
        ),
        title: Text(
          node.name,
          style: TextStyle(
            fontSize: 13,
            color: missing ? Colors.grey : null,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitleText,
          style: TextStyle(
            fontSize: 11,
            color: subtitleColor,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onOpen != null)
              IconButton(
                icon: const Icon(Icons.open_in_new, size: 16),
                tooltip: 'Open file',
                onPressed: onOpen,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            if (showRemoveButton && onRemove != null)
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: onRemove,
                tooltip: 'Remove file',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
          ],
        ),
      ),
    );
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
