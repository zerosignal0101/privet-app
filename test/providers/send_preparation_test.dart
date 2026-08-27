import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/providers/send_preparation.dart';

import '../support/test_daemon.dart';

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
}
