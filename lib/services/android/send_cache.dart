import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// Best-effort deletion of the temporary copies the Android send flow stages in
/// the app's cache directory.
///
/// The daemon only reads real filesystem paths, so any SAF `content://` URI is
/// copied into the cache before it can be sent (see `PrivetFileChannel` /
/// `PrivetShareChannel`, and `file_picker`'s own cache). Those copies are pure
/// staging: once the transfer they belong to is terminal (completed, failed or
/// cancelled) — or the selection that staged them is discarded — they should be
/// removed. Before this helper existed, nothing deleted them and a phone's cache
/// could grow past 2.6 GB.
///
/// Only files under the app's cache root are ever touched. Files the user owns
/// (picker results that already live on disk, clipboard saves, received files)
/// are never deleted, and on desktop nothing happens at all.
class SendCache {
  SendCache._();

  static String? _root;

  /// Test hook: force "Android mode" on the host so the cleanup logic can be
  /// exercised in unit tests.
  @visibleForTesting
  static bool enabledForTesting = false;

  /// Test hook: replace the resolved cache root with a scratch directory.
  @visibleForTesting
  static String? rootOverride;

  static bool get _android => enabledForTesting || Platform.isAndroid;

  /// The app's cache directory (Android `cacheDir`); on Android both
  /// `getTemporaryDirectory` and `getApplicationCacheDirectory` resolve here.
  static Future<String> root() async {
    final override = rootOverride;
    if (override != null) return override;
    final cached = _root;
    if (cached != null) return cached;
    final dir = await getTemporaryDirectory();
    _root = dir.path;
    return _root!;
  }

  /// Normalizes separators so Android (`/`) and Windows (`\`) paths compare
  /// consistently regardless of which separator a caller happened to use.
  static String _norm(String p) => p.replaceAll('\\', '/');

  static String _rootPrefix(String root) {
    final n = _norm(root);
    return n.endsWith('/') ? n : '$n/';
  }

  /// True when [path] is a staging copy inside the Android cache dir. Off
  /// Android this is always false, so desktop file selections are never treated
  /// as disposable.
  static Future<bool> isCachePath(String path) async {
    if (!_android || path.isEmpty) return false;
    try {
      return _norm(path).startsWith(_rootPrefix(await root()));
    } catch (_) {
      return false;
    }
  }

  /// Deletes each path that lives inside the cache dir. Missing paths and paths
  /// outside the cache (real user files) are skipped. Empty ancestor session
  /// directories are pruned up to the cache root so the `send-cache/<session>`
  /// dirs do not accumulate after their single file is removed.
  static Future<void> deleteIfCachedMany(Iterable<String> paths) async {
    if (!_android) return;
    final String cacheRoot;
    try {
      cacheRoot = await root();
    } catch (_) {
      return;
    }
    final prefix = _rootPrefix(cacheRoot);
    for (final path in paths) {
      if (path.isEmpty || !_norm(path).startsWith(prefix)) continue;
      try {
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.directory) {
          await Directory(path).delete(recursive: true);
        } else if (type == FileSystemEntityType.file) {
          await File(path).delete();
        }
      } catch (_) {
        // Already gone or locked — best effort.
      }
      _pruneEmptyParents(path, cacheRoot, prefix);
    }
  }

  static Future<void> deleteIfCached(String path) =>
      deleteIfCachedMany([path]);

  /// Walks up from [path] removing now-empty session dirs until it reaches the
  /// cache [root], which is never removed.
  static void _pruneEmptyParents(String path, String root, String prefix) {
    try {
      var dir = FileSystemEntity.isDirectorySync(path)
          ? Directory(path).parent
          : File(path).parent;
      while (_norm(dir.path).startsWith(prefix) &&
          _norm(dir.path) != _norm(root)) {
        if (dir.listSync().isNotEmpty) break;
        dir.deleteSync();
        dir = dir.parent;
      }
    } catch (_) {
      // Best effort.
    }
  }
}
