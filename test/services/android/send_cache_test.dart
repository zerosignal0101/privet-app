import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/android/send_cache.dart';

void main() {
  late Directory cacheRoot;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('privet-send-cache');
  });

  tearDown(() async {
    SendCache.enabledForTesting = false;
    SendCache.rootOverride = null;
    if (cacheRoot.existsSync()) {
      await cacheRoot.delete(recursive: true);
    }
  });

  void enableAndroidCache(String root) {
    SendCache.enabledForTesting = true;
    SendCache.rootOverride = root;
  }

  test('outside Android the staging cache is never considered disposable',
      () async {
    enableAndroidCache(cacheRoot.path);
    final inside = File('${cacheRoot.path}/a.bin');
    // enabledForTesting drives the Android check on the host.
    expect(await SendCache.isCachePath(inside.path), isTrue);

    // Default (host is not Android): nothing is treated as disposable even when
    // a path sits under the cache root.
    SendCache.enabledForTesting = false;
    expect(await SendCache.isCachePath(inside.path), isFalse);
  });

  test('isCachePath only matches files under the cache root', () async {
    enableAndroidCache(cacheRoot.path);
    final outside = await Directory.systemTemp.createTemp('privet-outside');
    addTearDown(() async {
      if (outside.existsSync()) await outside.delete(recursive: true);
    });

    expect(await SendCache.isCachePath('${cacheRoot.path}/x'), isTrue);
    expect(await SendCache.isCachePath('${outside.path}/x'), isFalse);
    expect(await SendCache.isCachePath(''), isFalse);
  });

  test('deleteIfCachedMany removes cached paths and prunes empty session dirs',
      () async {
    enableAndroidCache(cacheRoot.path);
    final staged = File('${cacheRoot.path}/privet/send-cache/s1/a.txt');
    await staged.parent.create(recursive: true);
    await staged.writeAsString('payload');
    // A sibling that must survive pruning.
    final sibling = File('${cacheRoot.path}/privet/send-cache/s2/b.txt');
    await sibling.parent.create(recursive: true);
    await sibling.writeAsString('payload');

    await SendCache.deleteIfCachedMany([staged.path, sibling.path]);

    expect(staged.existsSync(), isFalse);
    expect(sibling.existsSync(), isFalse);
    // Empty session dirs are pruned up to (not including) the cache root.
    expect(Directory('${cacheRoot.path}/privet/send-cache').existsSync(),
        isFalse);
    expect(cacheRoot.existsSync(), isTrue);
  });

  test('paths outside the cache root are never deleted', () async {
    enableAndroidCache(cacheRoot.path);
    final outside = await Directory.systemTemp.createTemp('privet-outside');
    addTearDown(() async {
      if (outside.existsSync()) await outside.delete(recursive: true);
    });
    final userFile = File('${outside.path}/keep.txt');
    await userFile.writeAsString('keep');

    await SendCache.deleteIfCachedMany([userFile.path]);
    expect(userFile.existsSync(), isTrue);
  });

  test('deleting a missing path is a no-op', () async {
    enableAndroidCache(cacheRoot.path);
    await SendCache.deleteIfCachedMany(['${cacheRoot.path}/never-existed']);
  });
}
