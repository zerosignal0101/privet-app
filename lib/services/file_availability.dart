import 'dart:io';

import 'package:flutter/foundation.dart';

import 'android/content_uri_helper.dart' as content_uri;
import 'android/original_ref_store.dart';
import 'android/send_cache.dart';

/// What history can honestly say about one file in a finished transfer.
enum FileAvailability {
  /// The file the user actually handed us is still reachable. The size shown
  /// comes from the transfer record.
  accessible,

  /// The file was sent from a disposable staging copy that the app cleaned up
  /// by design once the transfer ended. Nothing is wrong with the user's file —
  /// this copy simply is not kept around, so history cannot offer it for
  /// resend or opening.
  stagedCopyCleaned,

  /// The reference is genuinely gone: a path the app does not own was deleted,
  /// or a document reference whose permission is no longer held. This is the
  /// only case that may claim the file is not accessible.
  inaccessible,
}

/// Resolves whether a file in a finished transfer is still reachable.
///
/// Every probe is injectable so the decision can be exercised without a device,
/// a daemon, or a real file.
class FileAvailabilityResolver {
  const FileAvailabilityResolver._();

  /// Probes a `content://` reference; mirrors `PrivetFileChannel.checkContentUri`
  /// (opens a read file descriptor and reports whether the grant survives).
  static Future<bool> Function(String uri) checkContentUri =
      content_uri.checkContentUri;

  /// Whether a real filesystem path exists.
  static bool Function(String path) fileExists = (path) => File(path).existsSync();

  /// Whether a path is a disposable staging copy inside the app cache.
  static Future<bool> Function(String path) isCachePath = SendCache.isCachePath;

  /// Classifies one history file.
  ///
  /// The judgement follows the *original reference*, not the staged copy:
  ///
  /// 1. A recorded `content://` reference is probed with `checkContentUri`,
  ///    because a staging copy's absence says nothing about the document behind
  ///    it.
  /// 2. A recorded real path is probed with `File.exists`.
  /// 3. With no recorded reference, a staging path that no longer exists is
  ///    reported as [FileAvailability.stagedCopyCleaned] — it was disposable and
  ///    removed on purpose. Calling that "not accessible" would blame the user's
  ///    file for the app's cleanup.
  /// 4. Anything else keeps the existing behaviour: present means accessible,
  ///    absent means inaccessible.
  ///
  /// Every probe is treated as a negative result if it throws, so a broken
  /// channel degrades to "unreachable" instead of crashing the history list.
  static Future<FileAvailability> resolve({
    String? originalRef,
    String? stagedPath,
  }) async {
    final ref = normalizeOriginalRef(originalRef);

    if (ref != null) {
      if (ref.isContentUri) {
        return await _probe(() => checkContentUri(ref.value))
            ? FileAvailability.accessible
            : FileAvailability.inaccessible;
      }
      final path = ref.asPath;
      if (path != null && path.isNotEmpty) {
        return _probeSync(() => fileExists(path))
            ? FileAvailability.accessible
            : FileAvailability.inaccessible;
      }
    }

    if (stagedPath == null || stagedPath.isEmpty) {
      return FileAvailability.inaccessible;
    }
    if (_probeSync(() => fileExists(stagedPath))) {
      return FileAvailability.accessible;
    }
    // Gone. If it was a staging copy, that is our own doing and we say so
    // instead of accusing the user's file.
    if (await _probe(() => isCachePath(stagedPath))) {
      return FileAvailability.stagedCopyCleaned;
    }
    return FileAvailability.inaccessible;
  }

  /// A probe that throws means "cannot tell", which counts as unreachable —
  /// never as reachable, and never as a crash in the history list.
  static Future<bool> _probe(Future<bool> Function() probe) async {
    try {
      return await probe();
    } catch (_) {
      return false;
    }
  }

  static bool _probeSync(bool Function() probe) {
    try {
      return probe();
    } catch (_) {
      return false;
    }
  }
}

/// Wording for a file whose staging copy was cleaned up by design.
///
/// Deliberately does *not* claim the file is missing or inaccessible: the bytes
/// were delivered, and the user's file is untouched. It says what actually
/// happened and why the app can't re-offer that copy.
const String stagedCopyCleanedMessage =
    'Temporary copy cleaned up after sending — original file is fine';

/// Subtitle text for [availability]. Null means "render the size instead".
///
/// Only [FileAvailability.inaccessible] may say "File not accessible".
@visibleForTesting
String? availabilitySubtitle(FileAvailability availability) {
  switch (availability) {
    case FileAvailability.accessible:
      return null;
    case FileAvailability.stagedCopyCleaned:
      return stagedCopyCleanedMessage;
    case FileAvailability.inaccessible:
      return 'File not accessible';
  }
}