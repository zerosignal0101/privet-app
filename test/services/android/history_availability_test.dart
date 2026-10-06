import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/android/original_ref_store.dart';
import 'package:privet_app/services/file_availability.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the WP-R6 fix: history must judge a sent file by its *original*
/// reference, not by whether the disposable staging copy the daemon recorded
/// still happens to be on disk.
void main() {
  late Directory cacheRoot;
  late Set<String> existingPaths;
  late Set<String> reachableUris;
  late List<String> probedUris;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('privet-wpr6');
    existingPaths = <String>{};
    reachableUris = <String>{};
    probedUris = <String>[];
    SharedPreferences.setMockInitialValues({});

    // Default probe behaviour: an explicit set of "real" paths / reachable
    // URIs, so each test states only what it cares about.
    FileAvailabilityResolver.fileExists =
        (path) => existingPaths.contains(path);
    FileAvailabilityResolver.checkContentUri = (uri) async {
      probedUris.add(uri);
      return reachableUris.contains(uri);
    };
    FileAvailabilityResolver.isCachePath =
        (path) async => path.startsWith('${cacheRoot.path}/');
  });

  tearDown(() async {
    await OriginalRefStore.clear();
    if (cacheRoot.existsSync()) {
      await cacheRoot.delete(recursive: true);
    }
  });

  String staged(String name) => '${cacheRoot.path}/file_picker/1234/$name';

  test(
      '1. picker result (staged copy + content URI) is judged by URI '
      'reachability', () async {
    final path = staged('report.pdf');
    final uri = 'content://com.android.providers.media.documents/document/42';
    existingPaths.add(path);
    reachableUris.add(uri);
    await OriginalRefStore.record(path, normalizeOriginalRef(uri)!);

    final stored = await OriginalRefStore.lookup(path);
    expect(stored!.value, uri);
    expect(stored.isContentUri, isTrue);

    final availability = await FileAvailabilityResolver.resolve(
      originalRef: stored.value,
      stagedPath: path,
    );

    expect(availability, FileAvailability.accessible);
    // Probed by URI, and never decided by the staged copy's presence.
    expect(probedUris, contains(uri));
  });

  test(
      '2. staged copy already cleaned but the original URI is still reachable '
      '(core regression)', () async {
    final path = staged('photo.jpg');
    final uri = 'content://media/external/images/media/99';
    // Deliberately NOT in existingPaths: the send cache has deleted the copy.
    expect(File(path).existsSync(), isFalse);
    reachableUris.add(uri);
    await OriginalRefStore.record(path, normalizeOriginalRef(uri)!);

    final availability = await FileAvailabilityResolver.resolve(
      originalRef: (await OriginalRefStore.lookup(path))!.value,
      stagedPath: path,
    );

    expect(availability, FileAvailability.accessible);
  });

  test('3. an original reference that is a real path is judged by File.exists',
      () async {
    final path = staged('notes.txt');
    const original = '/storage/emulated/0/Documents/notes.txt';
    existingPaths.add(original);
    await OriginalRefStore.record(path, normalizeOriginalRef(original)!);

    final availability = await FileAvailabilityResolver.resolve(
      originalRef: (await OriginalRefStore.lookup(path))!.value,
      stagedPath: path,
    );

    expect(availability, FileAvailability.accessible);
    // A real path is not probed as a document URI.
    expect(probedUris, isEmpty);
  });

  test(
      '4. no original reference + a cleaned staging path must never claim the '
      "user's file is inaccessible", () async {
    final path = staged('legacy.bin');
    // Pre-WP-R6 history row: no mapping was ever recorded.
    expect(await OriginalRefStore.lookup(path), isNull);
    expect(await OriginalRefStore.dump(), isEmpty);

    final availability = await FileAvailabilityResolver.resolve(
      originalRef: null,
      stagedPath: path,
    );

    expect(availability, FileAvailability.stagedCopyCleaned);
    expect(availabilitySubtitle(availability), isNot('File not accessible'));
    expect(availabilitySubtitle(availability), stagedCopyCleanedMessage);
  });

  test('5. no reference, path is not a staging copy, and it is missing: '
      'unchanged behaviour', () async {
    const gone = '/storage/emulated/0/Download/gone-for-real.bin';
    expect(File(gone).existsSync(), isFalse);

    final availability = await FileAvailabilityResolver.resolve(
      originalRef: null,
      stagedPath: gone,
    );

    expect(availability, FileAvailability.inaccessible);
    expect(availabilitySubtitle(availability), 'File not accessible');
  });

  test('6. a throwing or unreachable content URI is treated as unreachable',
      () async {
    final path = staged('boom.bin');
    final uri = 'content://provider/boom';

    // (a) throws
    FileAvailabilityResolver.checkContentUri = (_) async {
      throw StateError('channel died');
    };
    expect(
      await FileAvailabilityResolver.resolve(
          originalRef: uri, stagedPath: path),
      FileAvailability.inaccessible,
    );

    // (b) reports unreachable
    FileAvailabilityResolver.checkContentUri = (_) async => false;
    expect(
      await FileAvailabilityResolver.resolve(
          originalRef: uri, stagedPath: path),
      FileAvailability.inaccessible,
    );

    // Neither outcome may fall through to the staged copy's own existence,
    // even though it is right there on disk.
    existingPaths.add(path);
    expect(
      await FileAvailabilityResolver.resolve(
          originalRef: uri, stagedPath: path),
      FileAvailability.inaccessible,
    );
  });

  test(
      '7. regression: the staged copy is never treated as the file\'s identity',
      () async {
    // Two sends of the SAME file produce two different staging events, each
    // with its own entry. Removing one copy must not change the other's
    // verdict, and the surviving row must still be judged by its own URI.
    final first = staged('dup.txt');
    final second = '${cacheRoot.path}/file_picker/5678/dup.txt';
    const uriA = 'content://provider/doc/A';
    const uriB = 'content://provider/doc/B';
    await OriginalRefStore.record(first, normalizeOriginalRef(uriA)!);
    await OriginalRefStore.record(second, normalizeOriginalRef(uriB)!);

    // Same file name, different staging path -> two distinct mappings.
    final dump = await OriginalRefStore.dump();
    expect(dump[first], uriA);
    expect(dump[second], uriB);
    expect(dump.length, 2);

    // The first copy is cleaned up and its URI is no longer granted, while the
    // second copy's URI still is.
    reachableUris
      ..clear()
      ..add(uriB);

    expect(
      await FileAvailabilityResolver.resolve(
        originalRef: (await OriginalRefStore.lookup(first))!.value,
        stagedPath: first,
      ),
      FileAvailability.inaccessible,
    );
    expect(
      await FileAvailabilityResolver.resolve(
        originalRef: (await OriginalRefStore.lookup(second))!.value,
        stagedPath: second,
      ),
      FileAvailability.accessible,
    );

    // Lock the invariant: with a reference on record, the staged copy's own
    // existence is never consulted, so it cannot decide the outcome.
    existingPaths
      ..clear()
      ..add(first);
    expect(
      await FileAvailabilityResolver.resolve(
        originalRef: (await OriginalRefStore.lookup(first))!.value,
        stagedPath: first,
      ),
      FileAvailability.inaccessible,
    );
  });
}