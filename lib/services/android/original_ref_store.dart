import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// Where a file the user handed us actually came from.
///
/// The Android send flow has to stage every outgoing file inside the app's
/// cache directory before the daemon can read it (the daemon only reads real
/// filesystem paths), and those staging copies are deleted once their transfer
/// reaches a terminal state. A staged copy is therefore *not* the file's
/// identity — it is a one-shot delivery artifact. History used to treat the
/// staged path as the identity, so every sent file looked "not accessible" once
/// its staging copy had been cleaned up, even though the user's file was fine.
///
/// This store keeps the association from staged path -> original reference so
/// history can ask about the original instead of the disposable copy.
class OriginalRef {
  /// `content://…` for a SAF/document reference, or a real filesystem path.
  final String value;

  const OriginalRef(this.value);

  /// True when [value] is a `content://` document reference rather than a path.
  bool get isContentUri => value.startsWith('content://');

  /// The filesystem path for a `file://` reference, or null when this is a
  /// `content://` URI (which has no filesystem path of its own).
  String? get asPath {
    if (isContentUri) return null;
    if (value.startsWith('file://')) {
      final parsed = Uri.tryParse(value);
      if (parsed != null && parsed.scheme == 'file') return parsed.toFilePath();
    }
    return value;
  }
}

/// Normalizes whatever a platform hands back as "the original reference" into
/// something worth storing, or null when it is not usable as one.
///
/// - `content://…` is kept verbatim: it is the only handle that survives scoped
///   storage, and it is what `PrivetFileChannel.checkContentUri` can probe.
/// - `file://…` is unwrapped to a real path, so `File.exists` can judge it.
/// - A bare absolute path is kept as-is.
/// - Anything else (empty, relative, opaque) is rejected rather than stored,
///   so history never records a reference it cannot possibly check.
OriginalRef? normalizeOriginalRef(String? raw) {
  if (raw == null) return null;
  final value = raw.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('content://')) return OriginalRef(value);
  if (value.startsWith('file://')) {
    final parsed = Uri.tryParse(value);
    final path = parsed?.toFilePath() ?? '';
    if (path.isEmpty || !path.startsWith('/')) return null;
    return OriginalRef(path);
  }
  if (value.startsWith('/')) return OriginalRef(value);
  return null;
}

/// Persistent staged-path -> original-reference map.
///
/// ### It also keys a picked *directory* root
///
/// The key is an opaque path string, so a staged **directory** root can be
/// keyed by the very same call — `record(rootPath, ref)` — and
/// `lookup(rootPath)` finds it again. That is what lets a picked folder be
/// re-staged as a whole tree (WP-R15): the tree URI is recorded against the
/// staged root, and when the send cache later deletes that root, the URI is
/// still reachable through this store.
///
/// This is deliberate, not an accident of the key type: a parallel "tree
/// store" would mean a second persistence file, a second eviction budget and a
/// second failure mode for what is the same fact about the same staged path. A
/// per-file reference is recorded under a file path and a tree reference under
/// a directory path, so the two never collide — `ResendStager` tells them apart
/// by looking a *directory* ancestor up, never a file one.
///
/// ### Why the key is the staged path
///
/// The staged path is the value the daemon echoes back as a history row's
/// `absolute_path` (the app sends the staged path verbatim and the engine
/// records what it was given), so it is the only identifier history has to
/// match on.
///
/// It is also *unique per staging event*, which is what makes it a trustworthy
/// key rather than a name:
///
/// - `file_picker` stages into `<cache>/file_picker/<currentTimeMillis>/<name>`
///   (`FileUtils.openFileStream`), so every pick gets its own timestamped dir.
/// - Our own SAF/share staging uses a monotonically increasing session counter
///   (`PrivetFileChannel` / `PrivetShareChannel` `AtomicLong`).
///
/// So sending the same file twice yields two distinct staged paths and two
/// distinct entries — no collision, and each history row resolves to the
/// reference its own staging event came from. Content hash was deliberately not
/// used as the key: two different files with identical bytes would collide,
/// which is precisely the case where history must not attribute one file's
/// reference to another.
///
/// Entries are stored in one bounded map and evicted oldest-first so the cache
/// cleanup that protects against unbounded growth applies here too.
class OriginalRefStore {
  OriginalRefStore._();

  /// Versioned so a future change to the stored shape can't misread old data.
  static const _key = 'privet.original_refs.v1';

  /// Upper bound on retained entries. A history row older than this many
  /// staged files falls back to the honest "staged copy was cleaned" wording
  /// rather than growing the preferences file without limit.
  static const _maxEntries = 512;

  /// Serializes writes so two concurrent `record` calls can't clobber each
  /// other's read-modify-write of the map.
  static Future<void> _queue = Future<void>.value();

  /// Test hook: keep the mapping in memory instead of in SharedPreferences.
  ///
  /// The same trick as `SendCache.rootOverride`, for the same reason. A widget
  /// test's fake clock does not reliably carry a SharedPreferences write made
  /// under `runAsync` into a later read performed by the widget under test, so
  /// a page-level test that must observe a recorded reference would see none and
  /// take the wrong branch. With a map here the same production
  /// `record`/`lookup` logic runs, synchronously, and the page test exercises
  /// the real code. Null means "use SharedPreferences", which is every real
  /// call.
  @visibleForTesting
  static Map<String, String>? inMemoryForTesting;

  /// Records that the file staged at [stagedPath] came from [ref].
  static Future<void> record(String stagedPath, OriginalRef ref) {
    if (stagedPath.isEmpty) return Future<void>.value();
    final next = _queue.then((_) => _record(stagedPath, ref));
    // Keep the chain alive even if one write fails, so a transient storage
    // error doesn't wedge every later record behind a rejected future.
    _queue = next.catchError((_) {});
    return next;
  }

  static Future<void> _record(String stagedPath, OriginalRef ref) async {
    final memory = inMemoryForTesting;
    if (memory != null) {
      // Re-inserting moves the key to the newest position for eviction order.
      memory.remove(stagedPath);
      memory[stagedPath] = ref.value;
      while (memory.length > _maxEntries) {
        memory.remove(memory.keys.first);
      }
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = _read(prefs);
      // Re-inserting moves the key to the newest position for eviction order.
      entries.remove(stagedPath);
      entries[stagedPath] = ref.value;
      while (entries.length > _maxEntries) {
        entries.remove(entries.keys.first);
      }
      await prefs.setString(_key, jsonEncode(entries));
    } catch (_) {
      // Persistence is best-effort: losing a mapping only costs history the
      // precise reference, and it degrades to the honest staged-copy wording.
    }
  }

  /// The original reference for [stagedPath], or null when none was recorded
  /// (e.g. a row written before this existed, or one that was evicted).
  static Future<OriginalRef?> lookup(String? stagedPath) async {
    if (stagedPath == null || stagedPath.isEmpty) return null;
    final memory = inMemoryForTesting;
    if (memory != null) return normalizeOriginalRef(memory[stagedPath]);
    try {
      final prefs = await SharedPreferences.getInstance();
      return normalizeOriginalRef(_read(prefs)[stagedPath]);
    } catch (_) {
      return null;
    }
  }

  /// Every current mapping, for diagnostics and tests.
  static Future<Map<String, String>> dump() async {
    final memory = inMemoryForTesting;
    if (memory != null) return Map<String, String>.from(memory);
    try {
      final prefs = await SharedPreferences.getInstance();
      return Map<String, String>.from(_read(prefs));
    } catch (_) {
      return const {};
    }
  }

  /// Drops all recorded mappings.
  static Future<void> clear() async {
    final memory = inMemoryForTesting;
    if (memory != null) {
      memory.clear();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // Best effort.
    }
  }

  /// Reads the stored map, preserving insertion order so the oldest key is the
  /// first one evicted. Tolerates malformed or legacy values by starting empty
  /// rather than throwing into the history UI.
  static Map<String, String> _read(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final result = <String, String>{};
      decoded.forEach((key, value) {
        if (key is String && value is String) result[key] = value;
      });
      return result;
    } catch (_) {
      return <String, String>{};
    }
  }
}