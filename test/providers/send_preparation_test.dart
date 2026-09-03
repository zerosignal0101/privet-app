import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/providers/send_preparation.dart';
import 'package:privet_app/providers/transfers.dart';
import 'package:privet_app/services/android/send_cache.dart';
import 'package:privet_app/services/ipc/events.dart';

import '../support/test_daemon.dart';

/// Lets async file deletion (started fire-and-forget) finish.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  test('send preparation requires files and a peer', () async {
    final dir = await Directory.systemTemp.createTemp('privet-prep');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final file = File('${dir.path}/a.txt');
    await file.writeAsString('hello');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = container.read(sendPreparationProvider.notifier);

    expect(n.state.isReady, isFalse);
    n.addFiles([file.path]);
    expect(n.state.entries, hasLength(1));
    expect(n.state.rootPaths, [file.path]);
    expect(n.state.isReady, isFalse); // no peer yet

    n.setPeer('fp', name: 'phone');
    expect(n.state.isReady, isTrue);

    n.removeByRelativePath('a.txt');
    expect(n.state.isReady, isFalse);
    expect(n.state.entries, isEmpty);
    expect(n.state.rootPaths, isEmpty);
  });

  test('directory adds are scanned recursively with prefixed paths', () async {
    final dir = await Directory.systemTemp.createTemp('privet-prep-dir');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    await File('${dir.path}/top.txt').writeAsString('1');
    await Directory('${dir.path}/sub').create();
    await File('${dir.path}/sub/nested.txt').writeAsString('2');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = container.read(sendPreparationProvider.notifier);

    n.addFiles([dir.path]);
    final name = dir.path.split(RegExp(r'[/\\]')).last;
    final rels = n.state.entries.map((e) => e.relativePath).toList();
    expect(
      rels,
      containsAll([
        name,
        '$name/top.txt',
        '$name/sub',
        '$name/sub/nested.txt',
      ]),
    );
    expect(n.state.rootPaths, [dir.path]);
    expect(n.state.totalSize, 2);

    // Removing the directory root clears the whole subtree.
    n.removeByRelativePath(name);
    expect(n.state.entries, isEmpty);
    expect(n.state.rootPaths, isEmpty);
  });

  test('send passes top-level paths to the daemon and returns the transfer id',
      () async {
    String? sentFp;
    List<dynamic>? sentPaths;
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'send': (id, params) {
        sentFp = params['device_fingerprint'] as String;
        sentPaths = params['paths'] as List<dynamic>;
        return okResponse(id, 'transfer_queued', {'transfer_id': 't-9'});
      },
    }));
    addTearDown(daemon.dispose);

    final n = daemon.container.read(sendPreparationProvider.notifier);
    n.addFileEntry(
        SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1));
    n.setPeer('fp1', name: 'phone');
    final id = await n.send();
    expect(id, 't-9');
    expect(sentFp, 'fp1');
    expect(sentPaths, ['/a.txt']);
    expect(daemon.container.read(sendPreparationProvider).sending, isFalse);
  });

  group('Android send-cache cleanup', () {
    late Directory cacheRoot;
    late File staged;

    setUp(() async {
      cacheRoot = await Directory.systemTemp.createTemp('privet-send-cache');
      SendCache.enabledForTesting = true;
      SendCache.rootOverride = cacheRoot.path;
      staged = File('${cacheRoot.path}/privet/send-cache/s1/a.txt');
      await staged.parent.create(recursive: true);
      await staged.writeAsString('x');
    });

    tearDown(() async {
      SendCache.enabledForTesting = false;
      SendCache.rootOverride = null;
      if (cacheRoot.existsSync()) {
        await cacheRoot.delete(recursive: true);
      }
    });

    test('staged copies are deleted once the transfer is terminal', () async {
      final daemon = await bootTestDaemon(scriptFromHandlers({
        'get_runtime_config': (id, _) =>
            okResponse(id, 'runtime_config', {
              'accept_all_trusted': false,
              'collision_policy': 'rename',
              'save_dir': r'C:\received',
            }),
        'send': (id, _) =>
            okResponse(id, 'transfer_queued', {'transfer_id': 't-clean'}),
      }));
      addTearDown(daemon.dispose);

      final n = daemon.container.read(sendPreparationProvider.notifier);
      n.addFileEntry(
          SendFileEntry(path: staged.path, relativePath: 'a.txt', size: 1));
      n.setPeer('fp1', name: 'phone');
      final id = await n.send();
      expect(id, 't-clean');
      // The daemon reads the source asynchronously after `send` returns, so the
      // staged file must survive until the terminal event.
      expect(staged.existsSync(), isTrue,
          reason: 'in-flight staging must not be deleted early');

      // Terminal event (completed) triggers cleanup.
      final transfers = daemon.container.read(activeTransfersProvider.notifier);
      transfers.applyEvent(TransferCompletedEvent(1, 't-clean'));
      await _settle();
      expect(staged.existsSync(), isFalse,
          reason: 'a completed send must clean its staging copies');
    });

    test('discarding the selection deletes the staged copies', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(sendPreparationProvider.notifier);
      n.addFiles([staged.path]);
      expect(n.state.entries, hasLength(1));

      await n.discardSelection();
      expect(n.state.entries, isEmpty);
      await _settle();
      expect(staged.existsSync(), isFalse,
          reason: 'discarded staging must not linger in the cache');
    });

    test('removing a file from the selection deletes its staging copy',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(sendPreparationProvider.notifier);
      n.addFiles([staged.path]);

      n.removeByRelativePath('a.txt');
      expect(n.state.entries, isEmpty);
      await _settle();
      expect(staged.existsSync(), isFalse);
    });

    test('real (non-cache) files are never deleted', () async {
      final real = await Directory.systemTemp.createTemp('privet-real');
      addTearDown(() async {
        if (real.existsSync()) await real.delete(recursive: true);
      });
      final realFile = File('${real.path}/keep.txt');
      await realFile.writeAsString('keep');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(sendPreparationProvider.notifier);
      n.addFiles([realFile.path]);

      await n.discardSelection();
      await _settle();
      expect(realFile.existsSync(), isTrue,
          reason: 'user-owned files are not cache staging');
    });
  });
}
