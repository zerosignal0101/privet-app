import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/android/resend_staging.dart';
import '../services/android/send_cache.dart';
import '../state/daemon_state.dart';
import '../utils/addr.dart';

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
    this.viaIp,
    this.viaError,
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

  /// Validated bare IP to send through, or null for "use the address the engine
  /// already has". Deliberately the *stripped* IP: the engine reads the port
  /// from the device record, so the port the user typed is not forwarded.
  final String? viaIp;

  /// Why the typed address was rejected. Non-null blocks sending, so an
  /// unusable address never becomes a request the daemon must refuse.
  final String? viaError;

  final bool sending;
  final String? error;

  bool get isReady =>
      rootPaths.isNotEmpty &&
      peerFingerprint != null &&
      !sending &&
      viaError == null;

  int get totalSize => entries.fold(0, (sum, e) => sum + e.size);

  SendPreparationState copyWith({
    List<SendFileEntry>? entries,
    List<String>? rootPaths,
    String? peerFingerprint,
    String? peerName,
    String? viaIp,
    String? viaError,
    bool? sending,
    String? error,
    bool clearPeer = false,
    bool clearError = false,
    bool clearVia = false,
  }) =>
      SendPreparationState(
        entries: entries ?? this.entries,
        rootPaths: rootPaths ?? this.rootPaths,
        peerFingerprint:
            clearPeer ? null : (peerFingerprint ?? this.peerFingerprint),
        peerName: clearPeer ? null : (peerName ?? this.peerName),
        // A null viaIp means "no override". An explicit value wins over
        // clearVia, so a single call can replace a stale address; clearVia on
        // its own is how the box is emptied.
        viaIp: viaIp ?? (clearVia ? null : this.viaIp),
        viaError: viaError ?? (clearVia ? null : this.viaError),
        sending: sending ?? this.sending,
        error: clearError ? null : (error ?? this.error),
      );
}

final sendPreparationProvider =
    NotifierProvider<SendPreparationNotifier, SendPreparationState>(
        SendPreparationNotifier.new);

class SendPreparationNotifier extends Notifier<SendPreparationState> {
  /// Cached staging files currently in flight: transfer id -> the top-level
  /// cache paths the daemon was handed for that send. Kept apart from the UI
  /// state so it survives `reset()`/`clearFiles()` (a send outlives the page
  /// that started it); entries are removed when the transfer reaches a terminal
  /// state and its copies are deleted.
  final Map<String, List<String>> _pendingCleanup = {};

  @override
  SendPreparationState build() => const SendPreparationState();

  /// Deletes the staging copies (if any) that belonged to [transferId] once its
  /// transfer is terminal. No-op for receive transfers and paths outside the
  /// cache; idempotent.
  Future<void> releaseTempFor(String transferId) async {
    final paths = _pendingCleanup.remove(transferId);
    if (paths == null || paths.isEmpty) return;
    await SendCache.deleteIfCachedMany(paths);
  }

  /// Discards the whole selection AND deletes the Android staging copies that
  /// were never handed to the daemon (the user removed them before sending).
  Future<void> discardSelection() async {
    final paths = state.entries.map((e) => e.path).toList();
    clearFiles();
    await SendCache.deleteIfCachedMany(paths);
  }

  /// Shows a transient blocking message (e.g. the selected recipient is not
  /// online) without touching the file selection, so the user can pick another
  /// device and retry.
  void setError(String message) => state = state.copyWith(error: message);

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
  /// `rootPaths` in sync so `isReady` stays accurate. Android staging copies
  /// that are dropped this way are deleted immediately — they were never handed
  /// to the daemon, so nothing will read them again.
  void removeByRelativePath(String relativePath) {
    final removedPaths = <String>[];
    for (final e in state.entries) {
      final rel = e.relativePath;
      if (rel == relativePath || rel.startsWith('$relativePath/')) {
        removedPaths.add(e.path);
      }
    }
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
    unawaited(SendCache.deleteIfCachedMany(removedPaths));
  }

  void clearFiles() {
    state = state.copyWith(entries: [], rootPaths: []);
  }

  /// Drop the whole selection (files, peer, in-flight send). The send page
  /// resets on open so a fresh intent never inherits a previous page's state.
  void reset() {
    state = const SendPreparationState();
  }

  /// Selects the recipient, replacing any previous one.
  ///
  /// Changing to a **different** receiver drops the pinned address and any
  /// address error with it: those describe the device the user was previously
  /// sending to. Keeping them is not a cosmetic slip — the address box's own
  /// rule is that a `via` already in the state wins over the remembered one
  /// (the user typed it on purpose, for a device met again on another network),
  /// so a surviving `viaIp` would be read as "the address the user chose for
  /// this device" when it was chosen for a different one. The box would then
  /// show the old address and [send] would hand it to the daemon: peer A's
  /// bytes addressed to peer A while the UI reads peer B.
  ///
  /// Re-selecting the *same* receiver is not a change, and must not destroy a
  /// half-typed address the user is in the middle of entering.
  void setPeer(String fingerprint, {String? name}) {
    final receiverChanged = state.peerFingerprint != fingerprint;
    state = state.copyWith(
      peerFingerprint: fingerprint,
      peerName: name,
      clearVia: receiverChanged,
    );
  }

  /// Applies the address the user typed to the send-to-address box.
  ///
  /// Stores either the normalised bare IP or a user-facing error — the send
  /// button goes disabled on the latter. Empty input clears the override
  /// entirely, which is the default "dial what the engine has" behaviour and
  /// must never be forced into an explicit address.
  void setVia(String input) {
    final parsed = parseViaAddress(input);
    if (parsed.isValid) {
      state = state.copyWith(clearVia: true, viaIp: parsed.ip);
    } else if (parsed.error == null) {
      // Empty box: drop the override and any error left from a previous edit.
      state = state.copyWith(clearVia: true);
    } else {
      state = state.copyWith(clearVia: true, viaError: parsed.error);
    }
  }

  /// Drops the recipient, along with the address that belonged to it.
  ///
  /// A pinned address with no receiver is an address for nobody: it would sit
  /// in the state as an override for whatever receiver is picked next, which is
  /// the same cross-receiver leak [setPeer] guards against.
  void clearPeer() {
    state = state.copyWith(clearPeer: true, clearVia: true);
  }

  void setSending(bool sending) => state = state.copyWith(sending: sending);

  /// Sends the selected files to [state.peerFingerprint]. Returns the daemon's
  /// transfer id, or null on failure (surfaced in [SendPreparationState.error]).
  ///
  /// [SendPreparationState.viaIp] is passed through as the `via` override when
  /// set; it is already a validated bare IP. A pending validation error aborts
  /// before the call, so a typo never reaches the daemon.
  Future<String?> send() async {
    final service = ref.read(daemonStateProvider).service;
    final fp = state.peerFingerprint;
    if (service == null || fp == null || state.rootPaths.isEmpty) return null;
    if (state.viaError != null) {
      state = state.copyWith(error: state.viaError);
      return null;
    }
    // Last gate before the daemon sees a path. The engine only opens real
    // filesystem paths; a `content://` URI reaches it as a plain "no such file"
    // io error that names neither the URI nor the fact that a URI was passed at
    // all, so refuse here where the mistake can still be named.
    for (final path in state.rootPaths) {
      if (looksLikeUri(path)) {
        state = state.copyWith(
            error: 'Cannot send ${_basename(path)}: this is a document '
                'reference, not a file on this device. Pick the file again.');
        return null;
      }
    }
    state = state.copyWith(sending: true, clearError: true);
    try {
      final transferId =
          await service.send(state.rootPaths, fp, via: state.viaIp);
      await _trackTempForRelease(transferId);
      state = state.copyWith(sending: false, clearError: true);
      return transferId;
    } catch (e) {
      state = state.copyWith(sending: false, error: e.toString());
      return null;
    }
  }

  /// Records which of the just-queued root paths are Android cache staging
  /// copies so they can be deleted when the transfer reaches a terminal state.
  /// The daemon reads these files asynchronously after `send` returns, so they
  /// must survive until the transfer actually completes or fails.
  Future<void> _trackTempForRelease(String transferId) async {
    final temp = <String>[];
    for (final p in state.rootPaths) {
      if (await SendCache.isCachePath(p)) temp.add(p);
    }
    if (temp.isEmpty) return;
    _pendingCleanup[transferId] = temp;
  }

  static String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).last;
}
