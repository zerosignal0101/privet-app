import 'dart:io';

import 'content_uri_helper.dart';
import 'original_ref_store.dart';
import 'send_cache.dart';

/// True when [path] is a URI rather than a filesystem path the daemon could
/// open.
///
/// The daemon (Rust, in another process on desktop and an embedded thread on
/// Android) only ever calls `std::fs::metadata`/`File::open` on the paths it is
/// given. A `content://…` string is not a path: handing one over produces a
/// plain `io` error — "No such file or directory" — with nothing in the message
/// to say the real mistake was passing a URI. So this is checked explicitly at
/// every boundary where a path is about to become a daemon request.
bool looksLikeUri(String path) {
  final value = path.trim();
  final match = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*):').firstMatch(value);
  if (match == null) return false;
  final scheme = match.group(1)!;
  // A Windows drive letter ("C:\…", "C:/…") is a one-character "scheme"
  // followed by a separator, which is a path, not a URI. Anything else that
  // matches the scheme grammar really is a URI.
  if (scheme.length == 1 && value.length > 2) {
    final next = value[match.end];
    if (next == '\\' || next == '/') return false;
  }
  return true;
}

/// Throws [ArgumentError] when [path] is a URI rather than a real path.
///
/// Used as the last gate before a path is handed to the daemon, so a URI can
/// never reach the engine even if some future caller forgets to filter.
void assertSendablePath(String path) {
  if (looksLikeUri(path)) {
    throw ArgumentError.value(
        path, 'path', 'the daemon can only read real filesystem paths, not URIs');
  }
}

/// One file as recorded in a finished transfer's history row.
///
/// Mirrors the fields of the IPC `HistoryFileDto` (`absolute_path`,
/// `relative_path`, `size`) without depending on the IPC layer, so the staging
/// rules stay testable on their own.
class ResendSource {
  final String? absolutePath;
  final String relativePath;
  final int size;

  const ResendSource({
    required this.relativePath,
    this.absolutePath,
    this.size = 0,
  });
}

/// One file from a finished send, resolved into something that can be sent
/// again — or into a concrete reason why it cannot.
class ResendCandidate {
  /// The path to hand to the daemon, or null when this file cannot be resent.
  final String? path;

  /// Why this file cannot be resent. Always names the file and the specific
  /// cause; never a generic "not found".
  final String? reason;

  /// The name to show in the UI (the history row's relative path).
  final String label;

  /// The recorded original reference, when one existed.
  final OriginalRef? ref;

  /// True when [path] is a *new* staging copy made for this resend, as opposed
  /// to a path that was already there.
  final bool restaged;

  const ResendCandidate({
    required this.label,
    required this.size,
    this.path,
    this.reason,
    this.ref,
    this.restaged = false,
  });

  final int size;

  bool get isSendable => path != null;
}

/// Turns the files of a finished send into paths that can be sent again.
///
/// ### Why this exists
///
/// On Android every outgoing file is staged into the app cache before the
/// daemon can read it, and that staging copy is deleted by design once the
/// transfer reaches a terminal state. The history row therefore records an
/// `absolute_path` that is *guaranteed* to be gone by the time the user looks at
/// it — resending it hands the daemon a path that no longer exists and the
/// transfer dies with the bare `io` error code, which says nothing about which
/// file or why.
///
/// So instead of reusing the recorded path, this re-derives a sendable one from
/// the file's *original reference* (the `content://` document the user picked,
/// or a real path), which survives the cleanup:
///
/// - a `content://` reference is probed first and, when still readable, a **new**
///   staging copy is made and recorded against the new transfer, so the new
///   copy is cleaned up on its own terminal event exactly like any other;
/// - a real path is used directly when it still exists;
/// - when neither is possible the file is reported with a specific, actionable
///   reason and **no transfer is ever started** — a pre-check, not a
///   trial-and-fail.
///
/// Every probe is injectable so the whole decision can be tested off-device.
class ResendStager {
  ResendStager({
    OriginalRefStoreLookup? lookupRef,
    Future<bool> Function(String uri)? probeUri,
    FileExistsFn? fileExists,
    Future<String?> Function(String uri)? stageCopy,
    Future<void> Function(String stagedPath, OriginalRef ref)? recordRef,
    CachePathFn? isCachePath,
  })  : _lookupRef = lookupRef ?? OriginalRefStore.lookup,
        _probeUri = probeUri ?? checkContentUri,
        _fileExists = fileExists ?? _defaultFileExists,
        _stageCopy = stageCopy ?? cacheToPath,
        _recordRef = recordRef ?? OriginalRefStore.record,
        _isCachePath = isCachePath ?? SendCache.isCachePath;

  /// Whether a path exists — as a file *or* a directory.
  ///
  /// A send can be rooted at a directory (the engine recurses it, see
  /// `prepare_paths`), and `File(p).existsSync()` is false for a directory, so
  /// using it here would refuse to resend a folder that is perfectly intact.
  static bool _defaultFileExists(String path) =>
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

  final Future<OriginalRef?> Function(String? stagedPath) _lookupRef;
  final Future<bool> Function(String uri) _probeUri;
  final bool Function(String path) _fileExists;
  final Future<String?> Function(String uri) _stageCopy;
  final Future<void> Function(String stagedPath, OriginalRef ref) _recordRef;
  final Future<bool> Function(String path) _isCachePath;

  /// Resolves one recorded file of a finished send into a sendable path, or
  /// into a concrete reason why it cannot be resent.
  Future<ResendCandidate> resolveOne({
    required String? absolutePath,
    required String relativePath,
    int size = 0,
  }) async {
    final ref = await _lookupRef(absolutePath);

    if (ref != null) {
      if (ref.isContentUri) {
        // Probe before doing any work: an unreadable document must not become a
        // transfer attempt that fails later.
        if (!await _safeProbe(() => _probeUri(ref.value))) {
          return ResendCandidate(
            label: relativePath,
            size: size,
            ref: ref,
            reason: '$relativePath: Privet no longer has permission to read '
                'this document — pick it again to resend it.',
          );
        }
        final staged = await _safeStage(() => _stageCopy(ref.value));
        if (staged == null || staged.isEmpty) {
          return ResendCandidate(
            label: relativePath,
            size: size,
            ref: ref,
            reason: '$relativePath: could not make a temporary copy of this '
                'document to resend it.',
          );
        }
        assertSendablePath(staged);
        // Bind the new copy to its own reference so this resend's copy is
        // cleaned up with this transfer, and so history can still explain it.
        await _safeRecord(() => _recordRef(staged, ref));
        return ResendCandidate(
          label: relativePath,
          size: size,
          path: staged,
          ref: ref,
          restaged: true,
        );
      }

      final path = ref.asPath;
      if (path != null && path.isNotEmpty) {
        if (_safeExists(path)) {
          assertSendablePath(path);
          return ResendCandidate(
            label: relativePath,
            size: size,
            path: path,
            ref: ref,
          );
        }
        return ResendCandidate(
          label: relativePath,
          size: size,
          ref: ref,
          reason: '$relativePath: the original file is no longer at $path.',
        );
      }
    }

    // No usable original reference. The recorded path may still be a real file
    // the app does not own (a desktop send, or a received file being
    // forwarded) — that is legitimately resendable.
    if (absolutePath != null && absolutePath.isNotEmpty) {
      assertSendablePath(absolutePath);
      if (_safeExists(absolutePath)) {
        return ResendCandidate(
          label: relativePath,
          size: size,
          path: absolutePath,
        );
      }
      final staged = await _safeCacheProbe(() => _isCachePath(absolutePath));
      if (staged) {
        return ResendCandidate(
          label: relativePath,
          size: size,
          reason: '$relativePath: the temporary copy made for this send was '
              'cleaned up, and Privet did not save where the file came from.',
        );
      }
      return ResendCandidate(
        label: relativePath,
        size: size,
        reason: '$relativePath: no longer on disk at $absolutePath.',
      );
    }

    return ResendCandidate(
      label: relativePath,
      size: size,
      reason: '$relativePath: this record has no file path to resend.',
    );
  }

  /// Resolves every recorded file of a finished send, preserving order.
  Future<List<ResendCandidate>> plan(List<ResendSource> sources) async {
    final out = <ResendCandidate>[];
    for (final source in sources) {
      out.add(await resolveOne(
        absolutePath: source.absolutePath,
        relativePath: source.relativePath,
        size: source.size,
      ));
    }
    return out;
  }

  static Future<bool> _safeProbe(Future<bool> Function() probe) async {
    try {
      return await probe();
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _safeStage(Future<String?> Function() stage) async {
    try {
      return await stage();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _safeRecord(Future<void> Function() record) async {
    try {
      await record();
    } catch (_) {
      // Best effort: losing the mapping only costs history a precise wording.
    }
  }

  static Future<bool> _safeCacheProbe(Future<bool> Function() probe) async {
    try {
      return await probe();
    } catch (_) {
      return false;
    }
  }

  bool _safeExists(String path) {
    try {
      return _fileExists(path);
    } catch (_) {
      return false;
    }
  }
}

typedef OriginalRefStoreLookup = Future<OriginalRef?> Function(String? stagedPath);
typedef FileExistsFn = bool Function(String path);
typedef CachePathFn = Future<bool> Function(String path);
