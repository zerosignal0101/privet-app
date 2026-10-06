// WP-R15: a picked FOLDER must be re-stageable as a whole tree.
//
// The gap this closes: `pickDirectory` used to return only the staged root path
// and never the tree URI it was copied from. So nothing anywhere remembered which
// `content://` tree a folder send came from. When the send cache deleted the
// staged tree on the transfer's terminal event, the folder was simply gone — an
// interrupted folder send could be neither resumed nor re-sent, and the app
// correctly refused with per-file reasons, which is a real failure but not a
// capability.
//
// What these tests lock in:
//   1. picking a folder records the tree URI against the staged root, and the
//      recording is durable across a store restart (it is persisted, not cached);
//   2. the "is this send tree-rooted?" rule recognises a folder send;
//   3. a multi-file pick is NOT mistaken for a tree — the same rule, both sides;
//   4. re-staging probes the grant BEFORE copying, and a lost grant yields a
//      specific reason and no copy at all;
//   5. a re-staged tree is one directory path, never N per-file paths.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/providers/send_preparation.dart';
import 'package:privet_app/services/android/content_uri_dir_helper.dart';
import 'package:privet_app/services/android/original_ref_store.dart';
import 'package:privet_app/services/android/resend_staging.dart';
import 'package:privet_app/services/android/send_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _treeUri =
    'content://com.android.providers.documents/tree/primary%3ADocuments%2Ftree';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('privet/file');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ContentUriDirectoryHelper.enabledForTesting = true;
  });

  tearDown(() async {
    ContentUriDirectoryHelper.enabledForTesting = false;
    messenger.setMockMethodCallHandler(channel, null);
    await OriginalRefStore.clear();
  });

  /// The recorded rows for a send rooted at a staged tree: nested relative
  /// paths, each with its own absolute path under [root].
  List<ResendSource> treeRows(String root) => [
        ResendSource(
            relativePath: 'sub/a.txt',
            absolutePath: '$root/sub/a.txt',
            size: 3),
        ResendSource(relativePath: 'b.txt', absolutePath: '$root/b.txt', size: 4),
      ];

  /// The recorded rows for a MULTI-FILE pick: flat names, staged side by side in
  /// one send-cache session directory. Structurally the nearest neighbour of a
  /// tree send, which is exactly why it is the discriminating case.
  List<ResendSource> multiFileRows(String sessionDir) => [
        ResendSource(relativePath: 'a.txt', absolutePath: '$sessionDir/a.txt'),
        ResendSource(relativePath: 'b.txt', absolutePath: '$sessionDir/b.txt'),
      ];

  group('picking a folder', () {
    test('1. records the tree URI against the staged root, and the root is what '
        'is returned to send', () async {
      const staged = '/data/user/0/app/cache/privet/send-cache/42/photos';
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pickDirectory');
        // Exactly the shape `PrivetFileChannel.onDirectoryResult` now returns.
        return {'path': staged, 'uri': _treeUri};
      });

      final root = await ContentUriDirectoryHelper.pickAndRecord();

      expect(root, staged,
          reason: 'the send still hands the daemon the staged root directory');
      final dump = await OriginalRefStore.dump();
      expect(dump.length, 1);
      expect(dump.keys.single, staged,
          reason: 'keyed by the staged root — the path that later disappears');
      expect(dump[staged], _treeUri,
          reason: 'the recorded value is the tree URI, verbatim, so the '
              'persisted grant can be re-read after a restart');
    });

    test('a cancelled pick records nothing', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);

      expect(await ContentUriDirectoryHelper.pickAndRecord(), isNull);
      expect(await OriginalRefStore.dump(), isEmpty);
    });

    test('a reply with a path but no URI is refused, so a half-picked folder is '
        'never sent', () async {
      messenger.setMockMethodCallHandler(
          channel, (call) async => {'path': '/cache/9/photos'});

      // A folder we cannot re-stage is the one-shot case this pair exists to
      // eliminate, so it is treated as "nothing usable" rather than sent.
      expect(await ContentUriDirectoryHelper.pickAndRecord(), isNull);
      expect(await OriginalRefStore.dump(), isEmpty);
    });
  });

  group('tree-rooted detection', () {
    test('2. a folder send IS recognised, and names the staged root', () async {
      const root = '/cache/privet/send-cache/42/photos';
      await OriginalRefStore.record(root, OriginalRef(_treeUri));

      final found = await findTreeRoot(treeRows(root));

      expect(found, isNotNull,
          reason: 'a recorded tree reference for the files\' common ancestor '
              'is what makes this a folder send');
      expect(found!.stagedRoot, root);
      expect(found.treeUri, _treeUri);
    });

    test('3. a multi-file pick is NOT mistaken for a tree', () async {
      // Per-file references, exactly as `ContentUriFilePicker` records them:
      // keyed by each staged FILE, never by the session directory.
      const session = '/cache/privet/send-cache/42';
      await OriginalRefStore.record('$session/a.txt',
          OriginalRef('content://p/document/1'));
      await OriginalRefStore.record('$session/b.txt',
          OriginalRef('content://p/document/2'));

      final found = await findTreeRoot(multiFileRows(session));

      expect(found, isNull,
          reason: 'two files picked side by side are not a folder; treating '
              'them as one would send the session directory, which is not what '
              'the user chose');
    });

    test('a single-file pick is not tree-rooted either', () async {
      const session = '/cache/privet/send-cache/42';
      await OriginalRefStore
          .record('$session/only.txt', OriginalRef('content://p/document/1'));

      final found = await findTreeRoot([
        ResendSource(relativePath: 'only.txt', absolutePath: '$session/only.txt'),
      ]);

      expect(found, isNull,
          reason: 'one file\'s common ancestor is the session directory, and '
              'the app never records a reference against that');
    });

    test('a tree whose files all sit in one subdirectory still resolves to the '
        'folder root, not to that subdirectory', () async {
      // The walk starts at the files' common ancestor and goes UP, so a folder
      // holding only `sub/` is still recognised as rooted at the folder.
      const root = '/cache/privet/send-cache/42/photos';
      await OriginalRefStore.record(root, OriginalRef(_treeUri));

      final found = await findTreeRoot([
        ResendSource(
            relativePath: 'sub/a.txt', absolutePath: '$root/sub/a.txt'),
        ResendSource(
            relativePath: 'sub/b.txt', absolutePath: '$root/sub/b.txt'),
      ]);

      expect(found?.stagedRoot, root,
          reason: 'the hierarchy the user picked is the whole point');
    });

    test('a recorded FILESYSTEM path is not a tree reference', () async {
      // A desktop folder, whose "original" is a real path rather than a
      // `content://` tree. Re-"staging" it as a tree would be meaningless, and
      // the per-file path below it is the right one.
      const root = '/home/u/photos';
      await OriginalRefStore.record(root, OriginalRef(root));

      expect(await findTreeRoot(treeRows(root)), isNull);
    });

    test('sources with a missing absolute path are not tree-rooted', () async {
      const root = '/cache/privet/send-cache/42/photos';
      await OriginalRefStore.record(root, OriginalRef(_treeUri));

      final found = await findTreeRoot([
        ResendSource(relativePath: 'a.txt', absolutePath: null),
        ResendSource(relativePath: 'b.txt', absolutePath: '$root/b.txt'),
      ]);

      expect(found, isNull,
          reason: 'a row with no path cannot be covered by one directory');
    });
  });

  group('re-staging a tree', () {
    TreeRoot rootOf() => const TreeRoot(
          stagedRoot: '/cache/privet/send-cache/42/photos',
          treeUri: _treeUri,
        );

    test('4. probes the grant BEFORE copying, and a lost grant copies nothing',
        () async {
      var probed = false;
      var staged = false;

      final result = await ResendStager(
        probeUri: (uri) async {
          expect(probed, false, reason: 'the copy must not start first');
          probed = true;
          return false; // permission revoked
        },
        stageTree: (uri) async {
          staged = true;
          return '/cache/privet/send-cache/99/photos';
        },
      ).restageTreeRoot(rootOf());

      expect(result.isSendable, isFalse);
      expect(probed, isTrue);
      expect(staged, false,
          reason: 'a revoked grant must cost one probe, not a half-copied tree');
      expect(result.reason, contains('permission'),
          reason: 'the reason must name the specific cause so the user knows '
              'to re-pick the folder');
    });

    test('an unreadable tree reports a reason and returns no path', () async {
      final result = await ResendStager(
        probeUri: (uri) async => true,
        stageTree: (uri) async => null, // grant held, but the tree is gone
      ).restageTreeRoot(rootOf());

      expect(result.isSendable, isFalse);
      expect(result.reason, contains('temporary copy'),
          reason: 'the copy failing is a different cause from losing the grant');
    });

    test('a successful re-stage returns ONE directory path and records the tree '
        'reference against the new copy', () async {
      const fresh = '/cache/privet/send-cache/99/photos';
      final recorded = <String, OriginalRef>{};

      final result = await ResendStager(
        probeUri: (uri) async => true,
        stageTree: (uri) async => fresh,
        recordRef: (path, ref) async => recorded[path] = ref,
      ).restageTreeRoot(rootOf());

      expect(result.rootPath, fresh);
      // ONE path, not N: an override of individual files would be flattened by
      // the engine and refused.
      expect(result.rootPath, isNot(contains('/sub/a.txt')));
      expect(recorded[fresh]?.value, _treeUri,
          reason: 'the new copy is itself a send-cache tree, so it is bound to '
              'the same reference and cleaned up with its own transfer');
    });

    test('the stager surfaces a channel-level failure as "cannot be restaged", '
        'never an exception', () async {
      final result = await ResendStager(
        probeUri: (uri) async => true,
        stageTree: (uri) async => throw StateError('provider died'),
      ).restageTreeRoot(rootOf());

      expect(result.isSendable, isFalse);
      expect(result.reason, isNotNull);
    });
  });

  group('the re-staged tree is cleaned up with its transfer', () {
    // This is a plain Dart test on purpose: it asserts notifier + `SendCache`
    // behaviour, which is where cleanup lives, and it touches real filesystem
    // paths. (A widget test's fake clock does not drive real I/O.)
    test('a re-staged tree is registered under the resuming transfer id, and a '
        'cached DIRECTORY is freed whole', () async {
      final tempRoot = Directory.systemTemp.createTempSync('privet-wpr15-clean');
      addTearDown(() {
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });
      final cacheRoot = '${tempRoot.path}/cache';
      // A re-staged tree: a real directory with a nested file, as a folder pick
      // copied again by the native side.
      final fresh = '$cacheRoot/privet/send-cache/2/photos';
      Directory('$fresh/sub').createSync(recursive: true);
      File('$fresh/sub/a.txt').writeAsBytesSync(List<int>.filled(16, 1));
      File('$fresh/b.txt').writeAsBytesSync(List<int>.filled(16, 2));

      SendCache.enabledForTesting = true;
      SendCache.rootOverride = cacheRoot;
      addTearDown(() {
        SendCache.enabledForTesting = false;
        SendCache.rootOverride = null;
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sendPreparationProvider.notifier);

      // A real user file OUTSIDE the cache must not be taken ownership of.
      final registered = await notifier.trackTempPathsFor(
          't-tree-cleanup', [fresh, '${tempRoot.path}/Documents/user.bin'],
          isCachePath: (p) async => p.startsWith('$cacheRoot/'));

      expect(registered, [fresh],
          reason: 'a directory is registered just like a file; a real user '
              'path outside the cache is not ours to delete');

      // The same call the page makes when it resumes with the root override.
      await notifier.releaseTempFor('t-tree-cleanup');

      expect(Directory(fresh).existsSync(), isFalse,
          reason: 'the whole re-staged tree is freed with its transfer, so the '
              'cache cleanup is not weakened by re-staging a directory');
    });
  });
}
