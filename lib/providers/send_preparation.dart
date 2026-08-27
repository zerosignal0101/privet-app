import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/daemon_state.dart';

/// A file (or directory marker) chosen for sending, with both the absolute
/// path (for the daemon) and the relative path (for the tree display).
class SendFileEntry {
  SendFileEntry({
    required this.path,
    required this.relativePath,
    this.size = 0,
    this.isDir = false,
  });

  final String path;
  final String relativePath;
  final int size;
  final bool isDir;
}

class SendPreparationState {
  const SendPreparationState({
    this.entries = const [],
    this.rootPaths = const [],
    this.peerFingerprint,
    this.peerName,
    this.sending = false,
    this.error,
  });

  /// Expanded entries (files + directory markers) for the tree display.
  final List<SendFileEntry> entries;

  /// Top-level paths the user added (files or directories), sent verbatim to
  /// the daemon — the engine recurses directories itself (ops.rs `prepare_dir`).
  final List<String> rootPaths;

  final String? peerFingerprint;
  final String? peerName;
  final bool sending;
  final String? error;

  bool get isReady => rootPaths.isNotEmpty && peerFingerprint != null && !sending;

  int get totalSize => entries.fold(0, (sum, e) => sum + e.size);

  SendPreparationState copyWith({
    List<SendFileEntry>? entries,
    List<String>? rootPaths,
    String? peerFingerprint,
    String? peerName,
    bool? sending,
    String? error,
    bool clearPeer = false,
    bool clearError = false,
  }) =>
      SendPreparationState(
        entries: entries ?? this.entries,
        rootPaths: rootPaths ?? this.rootPaths,
        peerFingerprint:
            clearPeer ? null : (peerFingerprint ?? this.peerFingerprint),
        peerName: clearPeer ? null : (peerName ?? this.peerName),
        sending: sending ?? this.sending,
        error: clearError ? null : (error ?? this.error),
      );
}

final sendPreparationProvider =
    NotifierProvider<SendPreparationNotifier, SendPreparationState>(
        SendPreparationNotifier.new);

class SendPreparationNotifier extends Notifier<SendPreparationState> {
  @override
  SendPreparationState build() => const SendPreparationState();

  void addFileEntry(SendFileEntry entry) {
    state = state.copyWith(
      entries: [...state.entries, entry],
      rootPaths: [...state.rootPaths, entry.path],
      clearError: true,
    );
  }

  /// Add files or directories. Directories are scanned recursively and their
  /// relative paths are prefixed with the directory name so remove-by-path is
  /// unambiguous.
  void addFiles(List<String> paths) {
    final entries = <SendFileEntry>[];
    final newRoots = <String>[];
    for (final p in paths) {
      if (state.rootPaths.contains(p)) continue;
      final type = FileSystemEntity.typeSync(p);
      if (type == FileSystemEntityType.file) {
        entries.add(SendFileEntry(
            path: p, relativePath: _basename(p), size: File(p).lengthSync()));
        newRoots.add(p);
      } else if (type == FileSystemEntityType.directory) {
        final dirName = _basename(p);
        entries.add(
            SendFileEntry(path: p, relativePath: dirName, isDir: true));
        _scanDir(Directory(p), entries, dirName);
        newRoots.add(p);
      }
    }
    state = state.copyWith(
      entries: [...state.entries, ...entries],
      rootPaths: [...state.rootPaths, ...newRoots],
      clearError: true,
    );
  }

  void _scanDir(Directory dir, List<SendFileEntry> out, String prefix) {
    for (final entity in dir.listSync(followLinks: false)) {
      final name = _basename(entity.path);
      final rel = prefix.isEmpty ? name : '$prefix/$name';
      if (entity is File) {
        out.add(SendFileEntry(
            path: entity.path, relativePath: rel, size: entity.lengthSync()));
      } else if (entity is Directory) {
        out.add(SendFileEntry(path: entity.path, relativePath: rel, isDir: true));
        _scanDir(entity, out, rel);
      }
    }
  }

  /// Remove a file (or a directory subtree) by its relative path, keeping
  /// `rootPaths` in sync so `isReady` stays accurate.
  void removeByRelativePath(String relativePath) {
    final remaining = state.entries.where((e) {
      if (e.relativePath == relativePath) return false;
      if (e.relativePath.startsWith('$relativePath/')) return false;
      return true;
    }).toList();
    final sep = Platform.pathSeparator;
    final remainingRoots = state.rootPaths.where((rp) {
      return remaining
          .any((e) => e.path == rp || e.path.startsWith(rp + sep));
    }).toList();
    state = state.copyWith(entries: remaining, rootPaths: remainingRoots);
  }

  void clearFiles() {
    state = state.copyWith(entries: [], rootPaths: []);
  }

  void setPeer(String fingerprint, {String? name}) {
    state = state.copyWith(peerFingerprint: fingerprint, peerName: name);
  }

  void clearPeer() {
    state = state.copyWith(clearPeer: true);
  }

  void setSending(bool sending) => state = state.copyWith(sending: sending);

  /// Sends the selected files to [state.peerFingerprint]. Returns the daemon's
  /// transfer id, or null on failure (surfaced in [SendPreparationState.error]).
  Future<String?> send() async {
    final service = ref.read(daemonStateProvider).service;
    final fp = state.peerFingerprint;
    if (service == null || fp == null || state.rootPaths.isEmpty) return null;
    state = state.copyWith(sending: true, clearError: true);
    try {
      final transferId = await service.send(state.rootPaths, fp);
      state = state.copyWith(sending: false, clearError: true);
      return transferId;
    } catch (e) {
      state = state.copyWith(sending: false, error: e.toString());
      return null;
    }
  }

  static String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).last;
}
