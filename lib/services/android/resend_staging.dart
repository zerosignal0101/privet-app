import 'dart:io';

import 'content_uri_dir_helper.dart';
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

/// A send that came from a **picked folder**, identified by the staged root the
/// tree was copied to and the `content://` tree URI it was copied from.
class TreeRoot {
  /// The staged directory root the original send was rooted at. For an Android
  /// folder pick this is `<cache>/privet/send-cache/<session>/<folderName>`.
  final String stagedRoot;

  /// The user's original SAF tree URI — the folder, not a copy of it.
  final String treeUri;

  const TreeRoot({required this.stagedRoot, required this.treeUri});
}

/// The result of trying to re-stage a send's whole tree.
class TreeRestage {
  /// The **new** root directory path to hand the daemon, or null when the tree
  /// could not be re-staged. Deliberately a single directory path: the engine
  /// recurses a directory (`prepare_paths`), which is what preserves the folder's
  /// hierarchy, whereas an override of individual files flattens
  /// `relative_path` to the file name and is refused by
  /// `check_override_matches_intent`.
  final String? rootPath;

  /// Why the tree could not be re-staged, naming the specific cause. Always set
  /// when [rootPath] is null.
  final String? reason;

  const TreeRestage({this.rootPath, this.reason});

  bool get isSendable => rootPath != null;
}


/// How many parent directories [findTreeRoot] is willing to walk up.
///
/// A bound rather than a stop-at-cache-root rule, so the decision stays
/// computable in a host test where the cache root is a temp dir. The walk is
/// only ever looking for a *directory* that carries a recorded tree reference,
/// and the app only ever records those against a staged folder root, so a handful
/// of levels is ample and a deep walk buys nothing.
const int kTreeRootSearchDepth = 8;

/// Finds the [TreeRoot] a send was rooted at, or null when the send was **not**
/// rooted at a picked folder.
///
/// ### The rule, stated
///
/// A send is **tree-rooted** when all of these hold:
///
/// 1. every recorded source has a non-empty `absolutePath` (a path the engine
///    actually read);
/// 2. those paths share a common ancestor directory, computed by walking up
///    from the first file's parent until every file is contained — so a
///    directory send whose files sit in one subdirectory still resolves to the
///    folder root, not to that subdirectory;
/// 3. **a tree reference is recorded for some ancestor of that common ancestor,
///    walking upwards and taking the first hit** — the staged root a folder pick
///    produced.
///
/// Rule 3 is what separates a folder pick from a multi-file pick, and it works
/// because of where references are keyed. A folder pick records one reference
/// against the staged **directory** root; a multi-file pick records one against
/// each staged **file**. This function only ever looks up **directories** — the
/// ancestors of the recorded files — so a per-file reference can never be found,
/// and a multi-file pick has no recorded reference at its common ancestor (the
/// send-cache *session* directory, which the app never records against). A
/// one-file pick is likewise not tree-rooted: its common ancestor is the session
/// directory, not a folder root.
///
/// The lookup is injectable so both sides of rule 3 are testable without a
/// device or a real SAF grant.
Future<TreeRoot?> findTreeRoot(
  List<ResendSource> sources, {
  OriginalRefStoreLookup? lookupRef,
}) async {
  final lookup = lookupRef ?? OriginalRefStore.lookup;
  if (sources.isEmpty) return null;
  if (sources.any((s) => s.absolutePath == null || s.absolutePath!.isEmpty)) {
    return null;
  }
  final first = sources.first.absolutePath!;
  final firstParent = _parentOf(first);
  if (firstParent == null || firstParent.isEmpty) return null;

  // Rule 2: the deepest directory containing every recorded file.
  var common = firstParent;
  for (final s in sources) {
    final parent = _parentOf(s.absolutePath!);
    if (parent == null || parent.isEmpty) return null;
    common = _sharedAncestor(common, parent);
    if (common.isEmpty) return null;
  }

  // Rule 3: the first ancestor carrying a recorded tree reference.
  var dir = common;
  for (var depth = 0; depth <= kTreeRootSearchDepth; depth++) {
    final ref = await _safeTreeLookup(() => lookup(dir));
    // A tree reference is a `content://` URI: that is what makes it a folder we
    // can copy again. A recorded *filesystem* path is a file the user handed us
    // directly, and re-"staging" it as a tree would be meaningless.
    if (ref != null && ref.isContentUri) {
      return TreeRoot(stagedRoot: dir, treeUri: ref.value);
    }
    final parent = _parentOf(dir);
    if (parent == null || parent.isEmpty || parent == dir) return null;
    dir = parent;
  }
  return null;
}

Future<OriginalRef?> _safeTreeLookup(
    Future<OriginalRef?> Function() lookup) async {
  try {
    return await lookup();
  } catch (_) {
    return null;
  }
}

/// The parent directory of [path], or null when it has none. `/` is its own
/// parent sentinel, which terminates the upward walks above.
String? _parentOf(String path) {
  final norm = path.replaceAll('\\', '/');
  final idx = norm.lastIndexOf('/');
  if (idx < 0) return null;
  if (idx == 0) return '/';
  return norm.substring(0, idx);
}

/// The deepest directory containing both [a] and [b], or '' when they are
/// unrelated.
String _sharedAncestor(String a, String b) {
  if (a == b) return a;
  final ap = a.replaceAll('\\', '/');
  final bp = b.replaceAll('\\', '/');
  // `/x/y` contains `/x/y/z` but not `/x/yz`: compare whole segments.
  if (ap.startsWith('$bp/')) return bp;
  if (bp.startsWith('$ap/')) return ap;
  final aParent = _parentOf(ap);
  if (aParent == null || aParent == ap) return '';
  return _sharedAncestor(aParent, b);
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
    TreeStageFn? stageTree,
  })  : _lookupRef = lookupRef ?? OriginalRefStore.lookup,
        _probeUri = probeUri ?? ContentUriChannel.check,
        _fileExists = fileExists ?? _defaultFileExists,
        _stageCopy = stageCopy ?? cacheToPath,
        _recordRef = recordRef ?? OriginalRefStore.record,
        _isCachePath = isCachePath ?? SendCache.isCachePath,
        _stageTree = stageTree ?? ContentUriDirectoryHelper.restageTree;

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
  final Future<String?> Function(String treeUri) _stageTree;

  /// Re-stages a send that was rooted at a picked **folder**, as a whole tree.
  ///
  /// This is the tree counterpart of [plan], and it exists because the per-file
  /// path is not merely incomplete for a nested send but *wrong*: an override is
  /// a list of individual paths, so the engine takes the `else` branch beside
  /// `meta.is_dir()` for each and derives `relative_path = file_name`, flattening
  /// `sub/a.txt` to `a.txt` — which `check_override_matches_intent` then refuses
  /// against the recorded nested set. Handing back the **new root directory**
  /// instead lets `prepare_paths` recurse it, so the hierarchy the user actually
  /// picked is the hierarchy that is sent.
  ///
  /// The grant is **probed before anything is copied**, so a folder whose
  /// permission was revoked costs one round trip and a specific message rather
  /// than a silent partial copy; and a failure here never starts a transfer —
  /// the caller reports [TreeRestage.reason] and stops. That is the same
  /// pre-check discipline [resolveOne] follows per file.
  Future<TreeRestage> restageTreeRoot(TreeRoot root) async {
    // Probe first: a lost grant must not become a half-copied tree.
    if (!await _safeProbe(() => _probeUri(root.treeUri))) {
      return const TreeRestage(
        reason: 'Privet no longer has permission to read this folder — '
            'pick it again to resend it.',
      );
    }
    final staged = await _safeStage(() => _stageTree(root.treeUri));
    if (staged == null || staged.isEmpty) {
      return const TreeRestage(
        reason: 'this folder could not be read to make a temporary copy of it.',
      );
    }
    // The daemon reads real paths; a URI must never reach it. Checked by the
    // stager and again by the caller, like the per-file path.
    assertSendablePath(staged);
    // Bind the new copy to the same tree reference, so this copy is cleaned up
    // with its own terminal event and history can still explain what it was.
    final ref = normalizeOriginalRef(root.treeUri);
    if (ref != null) {
      await _safeRecord(() => _recordRef(staged, ref));
    }
    return TreeRestage(rootPath: staged);
  }

  /// Locates the tree a send was rooted at, if it was rooted at one.
  Future<TreeRoot?> treeRootOf(List<ResendSource> sources) =>
      findTreeRoot(sources, lookupRef: _lookupRef);

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

/// Copies a picked SAF tree into a fresh send-cache session and returns the new
/// root directory path, or null when it cannot be copied.
typedef TreeStageFn = Future<String?> Function(String treeUri);
