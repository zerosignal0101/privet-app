import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'original_ref_store.dart';

/// A folder the user picked on Android, as both halves of its identity.
///
/// [stagedRoot] is the disposable copy inside the app cache that the daemon
/// actually reads (it recurses the directory, which is how the receiver sees
/// the same hierarchy). [treeUri] is the user's real `content://` SAF tree —
/// the folder itself, not a copy of it.
///
/// The two are deliberately kept apart, exactly as `PickedContentFile` keeps a
/// staged file apart from its `content://` document. The staging copy is deleted
/// by design when its transfer reaches a terminal state, while the tree URI —
/// because the native side takes a *persistable* read grant for it — is still
/// readable after a restart. That is what makes an interrupted folder send
/// re-stageable: without the URI the folder pick was a one-shot, and a
/// cancelled or failed folder send could be neither resumed nor re-sent.
class PickedDirectory {
  final String stagedRoot;
  final String treeUri;

  const PickedDirectory({required this.stagedRoot, required this.treeUri});
}

/// Picks a directory on Android via SAF (`ACTION_OPEN_DOCUMENT_TREE`) and
/// returns the top-level cached directory path together with the tree URI it
/// was copied from.
///
/// The native side copies the tree to `<cache>/privet/send-cache/<session>/`
/// preserving relative paths, and returns `<session>/<folderName>` — the path
/// the send flow hands verbatim to the daemon, which recurses it itself (so the
/// directory hierarchy survives on the receiving side).
class ContentUriDirectoryHelper {
  static const _channel = MethodChannel('privet/file');

  /// Test hook: force the Android path on a host test machine. Mirrors
  /// `ContentUriFilePicker.enabledForTesting`, which is the same trick.
  @visibleForTesting
  static bool enabledForTesting = false;

  /// Test hook: substitute the tree copy itself, so a caller can be driven
  /// off-device without the `privet/file` channel.
  ///
  /// This is the same seam style as `ContentUriChannel.check`/`open`: a
  /// platform channel round trip is delivered on the real event loop, which a
  /// widget test's fake clock does not drive, so a page-level test that awaits
  /// one can deadlock. Overriding the function keeps the production code path
  /// (`restageTreeRoot` → probe → copy → record) intact while making the copy
  /// itself synchronous. Null means "use the real channel".
  @visibleForTesting
  static Future<String?> Function(String treeUri)? restageTreeOverride;

  static bool get _android => enabledForTesting || Platform.isAndroid;

  /// Returns the picked folder, or null when the user cancels, the picker is
  /// unavailable, or copying fails. A cancelled picker is not an error.
  static Future<PickedDirectory?> pickAndCacheDirectory() async {
    if (kIsWeb || !_android) return null;
    Object? raw;
    try {
      raw = await _channel.invokeMethod<Object?>('pickDirectory');
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('[SAF] pickDirectory error: $e');
      return null;
    }
    return parsePickedDirectory(raw);
  }

  /// Decodes the native reply into a [PickedDirectory].
  ///
  /// Both halves are required. A reply missing the staged path cannot be sent,
  /// and a reply missing the URI is the one-shot case this pair exists to
  /// eliminate — returning a half-picked folder would silently reintroduce an
  /// unre-stageable send, so it is treated as "nothing usable came back" and the
  /// caller sends nothing.
  @visibleForTesting
  static PickedDirectory? parsePickedDirectory(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final uri = raw['uri'];
    if (path is! String || path.isEmpty) return null;
    if (uri is! String || uri.isEmpty) return null;
    return PickedDirectory(stagedRoot: path, treeUri: uri);
  }

  /// Pick, remember, and return the staged root path.
  ///
  /// The tree URI is persisted **now**, while the pick still knows it, and is
  /// keyed by the staged root — the path the engine records as the send's
  /// source, and the one that later disappears. Recording it here (rather than
  /// in the page) keeps the "remember what the user gave us" rule in one place,
  /// the same place the per-file flow keeps it.
  ///
  /// A tree URI that is not a usable reference is still returned for sending
  /// (the staged copy is valid for this transfer); it simply has no original to
  /// remember, which degrades that one send to the honest "temporary copy was
  /// cleaned up" wording later rather than failing the pick.
  @visibleForTesting
  static Future<String?> recordTreeUri(PickedDirectory picked) async {
    final ref = normalizeOriginalRef(picked.treeUri);
    if (ref != null) {
      await OriginalRefStore.record(picked.stagedRoot, ref);
    } else {
      debugPrint('[SAF] unusable tree reference, sending anyway: '
          '${picked.treeUri}');
    }
    return picked.stagedRoot;
  }

  /// The whole Android folder-pick side of the send flow in one call.
  static Future<String?> pickAndRecord() async {
    final picked = await pickAndCacheDirectory();
    if (picked == null) return null;
    return recordTreeUri(picked);
  }

  /// Copies a previously picked tree again, into a **fresh** send-cache
  /// session, and returns the new root directory path.
  ///
  /// This is the re-stage half. The original pick's staging copy is deleted
  /// when its transfer goes terminal, so a folder send that has to be resumed
  /// or re-sent has to copy the user's tree in again. It is deliberately not a
  /// per-file operation: a folder send's whole value is its hierarchy, and the
  /// engine flattens `relative_path` to the file name for each individual path
  /// in an override, so re-staging the files one by one would produce a file
  /// set the engine refuses.
  ///
  /// Returns null when the tree cannot be copied — the grant was revoked, the
  /// tree was removed, or the provider refuses. It never throws, so a caller
  /// that cannot reach the folder can report a reason and start no transfer.
  static Future<String?> restageTree(String treeUri) async {
    final override = restageTreeOverride;
    if (override != null) return override(treeUri);
    if (kIsWeb || !_android) return null;
    try {
      final path =
          await _channel.invokeMethod<String>('stageDirectory', {'uri': treeUri});
      if (path == null || path.isEmpty) return null;
      // The new copy is itself a send-cache tree: bind the same reference to it
      // so this copy is cleaned up with its own transfer and history can still
      // explain what it was, exactly as `ResendStager` does for a re-staged file.
      final ref = normalizeOriginalRef(treeUri);
      if (ref != null) await OriginalRefStore.record(path, ref);
      return path;
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('[SAF] stageDirectory error: $e');
      return null;
    }
  }
}
