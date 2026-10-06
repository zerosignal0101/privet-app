import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

import 'original_ref_store.dart';

/// One file the user chose in the Android SAF file picker.
///
/// [stagedPath] is the throwaway copy inside the app cache the daemon actually
/// reads; [uri] is the user's original `content://` document reference and is
/// the file's identity. They are deliberately kept apart: the staging copy is
/// deleted by design once its transfer is terminal, while the URI — because the
/// native side takes a *persistable* read grant for it — is still readable after
/// an app or device restart.
class PickedContentFile {
  final String stagedPath;
  final String uri;

  const PickedContentFile({required this.stagedPath, required this.uri});
}

/// Picks one or more files on Android via SAF (`ACTION_OPEN_DOCUMENT`) and
/// returns each selected document together with its staging copy.
///
/// This exists instead of `file_picker` on Android because that plugin's
/// delegate launches the same intent *without*
/// `FLAG_GRANT_PERSISTABLE_URI_PERMISSION` and never calls
/// `takePersistableUriPermission`. The `content://` URI it hands back as
/// `identifier` is therefore only granted for the life of the process, so after
/// a restart history would probe a URI it can no longer read and report the
/// user's file as inaccessible — the exact symptom this replaces.
class ContentUriFilePicker {
  static const _channel = MethodChannel('privet/file');

  /// Test hook: force the Android path on a host test machine.
  @visibleForTesting
  static bool enabledForTesting = false;

  static bool get _android => enabledForTesting || Platform.isAndroid;

  /// Launches the picker and returns the selections, index-aligned with what the
  /// user chose.
  ///
  /// Returns an empty list when the user cancels, when the platform is not
  /// Android, or when the native side reports a failure — a cancelled picker is
  /// not an error.
  static Future<List<PickedContentFile>> pickFiles() async {
    if (kIsWeb || !_android) return const [];
    List<Object?>? raw;
    try {
      raw = await _channel.invokeMethod<List<Object?>>('pickFiles');
    } on MissingPluginException {
      return const [];
    } catch (e) {
      debugPrint('[SAF] pickFiles error: $e');
      return const [];
    }
    return parsePickedFiles(raw);
  }

  /// Decodes the native reply into pairs, dropping entries that cannot be acted
  /// on (a null `path` means that document's staging copy failed, so there is
  /// nothing to send and no staging path to key a reference by).
  @visibleForTesting
  static List<PickedContentFile> parsePickedFiles(List<Object?>? raw) {
    if (raw == null) return const [];
    final picked = <PickedContentFile>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final path = item['path'];
      final uri = item['uri'];
      if (path is! String || path.isEmpty) continue;
      if (uri is! String || uri.isEmpty) continue;
      picked.add(PickedContentFile(stagedPath: path, uri: uri));
    }
    return picked;
  }

  /// Records the original reference of every picked file and returns the staged
  /// paths to hand to the daemon.
  ///
  /// The reference is persisted *now*, while the pick still knows it: the
  /// staging copy that history keys on will be deleted once the transfer ends,
  /// and this mapping is the only thing that can say which user file it was.
  ///
  /// A file whose `uri` is not a usable reference is still returned for sending
  /// (the staging copy is valid); it simply has no original to remember, which
  /// degrades that one history row to the honest "staging copy was cleaned"
  /// wording instead of failing the whole selection.
  @visibleForTesting
  static Future<List<String>> recordOriginalRefs(
      List<PickedContentFile> picked) async {
    final paths = <String>[];
    for (final file in picked) {
      final ref = normalizeOriginalRef(file.uri);
      if (ref != null) {
        await OriginalRefStore.record(file.stagedPath, ref);
      } else {
        debugPrint('[SAF] unusable original reference, sending anyway: '
            '${file.uri}');
      }
      paths.add(file.stagedPath);
    }
    return paths;
  }

  /// Pick, remember, and return the staged paths — the whole Android file-pick
  /// side of the send flow in one call.
  static Future<List<String>> pickAndRecord() async {
    final picked = await pickFiles();
    if (picked.isEmpty) return const [];
    return recordOriginalRefs(picked);
  }
}
