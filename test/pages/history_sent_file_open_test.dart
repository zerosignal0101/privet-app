// WP-R8: a file the app *sent* must be openable from history, even though the
// staging copy the daemon recorded is deleted by design once the transfer ends.
//
// The recorded path is a one-shot delivery artifact. The file the user actually
// chose is the original reference (a `content://` document or a real path), so
// "open" has to target that reference instead. These tests pin all three cases:
//   - a reachable `content://` original gets a button that opens the URI,
//   - a reachable real-path original opens that path, not the deleted copy,
//   - with no surviving original (`stagedCopyCleaned`) there is no button at all,
// plus the two guards: a received file's behaviour is untouched, and send
// preparation (which passes no reference map) keeps the exists-on-disk default.
//
// The URI cases drive the real `HistoryPage` over a fake `privet/file` channel.
// The path cases assert *which path* would be handed to the opener, so they
// exercise `FileTreeView` directly with a recording callback — `OpenFilex`
// spawns a real desktop opener on a host machine, which is not something a
// widget test should do.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/models/file_tree.dart';
import 'package:privet_app/pages/history_page.dart';
import 'package:privet_app/services/android/content_uri_helper.dart';
import 'package:privet_app/services/android/original_ref_store.dart';
import 'package:privet_app/services/file_availability.dart';
import 'package:privet_app/widgets/file_tree_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_daemon.dart';

const String kUri = 'content://com.android.providers.media.documents/document/77';

FileTreeNode fileNode(String path, {int size = 4096}) => FileTreeNode(
      name: path.split('/').last,
      relativePath: path.split('/').last,
      fullPath: path,
      size: size,
    );

Map<String, dynamic> _entry(String id, {String direction = 'send'}) => {
      'transfer_id': id,
      'direction': direction,
      'peer_device_fingerprint': 'peer-$id',
      'peer_name': 'tablet',
      'root_name': '$id-root',
      'file_count': 1,
      'total_bytes': 4096,
      'status': 'completed',
      'started_ts': 1,
      'finished_ts': 2,
    };

Map<String, dynamic> _detail(String id, String absolutePath,
        {String direction = 'send'}) =>
    {
      'transfer_id': id,
      'direction': direction,
      'peer_device_fingerprint': 'peer-$id',
      'peer_name': 'tablet',
      'root_name': '$id-root',
      'status': 'completed',
      'started_ts': 1,
      'finished_ts': 2,
      'files': [
        {
          'relative_path': 'report.pdf',
          'absolute_path': absolutePath,
          'size': 4096,
          'status': 'complete',
        },
      ],
    };

void main() {
  late Directory tempRoot;
  late List<String> openedUris;
  late Set<String> existingPaths;
  late Set<String> reachableUris;
  late Set<String> openableUris;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('privet-wpr8');
    openedUris = <String>[];
    existingPaths = <String>{};
    reachableUris = <String>{};
    openableUris = <String>{};
    SharedPreferences.setMockInitialValues({});

    FileAvailabilityResolver.fileExists = existingPaths.contains;
    FileAvailabilityResolver.isCachePath =
        (path) async => path.startsWith('${tempRoot.path}/');
    FileAvailabilityResolver.checkContentUri =
        (uri) async => reachableUris.contains(uri);

    // Fake `privet/file` channel. `openableUris` is deliberately separate from
    // `reachableUris`: a document can still be *readable* (so history offers
    // the button) while the provider refuses to hand it to a viewer.
    ContentUriChannel.open = (uri) async {
      openedUris.add(uri);
      return openableUris.contains(uri);
    };
  });

  tearDown(() async {
    // tearDown runs in the real zone, so the static write chain is safe here.
    await OriginalRefStore.clear();
    if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
  });

  /// Records a staged path -> original reference mapping.
  ///
  /// This must run inside `runAsync`: `OriginalRefStore` serializes writes
  /// through a static future chain, and a chain built inside a widget test's
  /// fake-async zone can never be awaited from the *next* test's zone, which
  /// deadlocks the file. `runAsync` puts the chain in the real zone.
  Future<void> recordRef(
          WidgetTester tester, String path, String ref) =>
      tester.runAsync(() => OriginalRefStore.record(path, normalizeOriginalRef(ref)!));

  /// Reads a recorded reference, with the same fake-async caveat.
  Future<OriginalRef?> lookupRef(WidgetTester tester, String path) =>
      tester.runAsync<OriginalRef?>(() => OriginalRefStore.lookup(path));

  /// A staging path inside the app cache — the kind the send cache deletes.
  String staged(String name) => '${tempRoot.path}/send-cache/sess-1/$name';

  /// Boots a one-record history page whose single file sits at [absolutePath],
  /// and shows it with its detail expanded.
  Future<void> showHistory(WidgetTester tester, {
    required String id,
    required String absolutePath,
    String direction = 'send',
  }) async {
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'list_history': (rid, params) =>
          okResponse(rid, 'history', [_entry(id, direction: direction)]),
      'get_history_detail': (rid, params) => okResponse(
          rid,
          'history_detail',
          _detail(params['transfer_id'] as String, absolutePath,
              direction: direction)),
    }));
    addTearDown(daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: const MaterialApp(home: HistoryPage()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('tablet'));
    await tester.pumpAndSettle();
  }

  /// Tears the page back down once a test is done with it. A tree left
  /// standing with a live `RefreshIndicator` / in-flight future can make the
  /// *next* test's `pumpAndSettle` wait forever on a frame that never comes.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  // ---- 1. a sent file whose original is a reachable content:// URI ----------
  testWidgets(
      '1. sent file with a reachable content:// original shows Open and opens '
      'the URI, not the deleted staging path', (tester) async {
    final path = staged('report.pdf');
    // The staging copy is gone, by design.
    expect(File(path).existsSync(), isFalse);
    reachableUris.add(kUri);
    openableUris.add(kUri);
    await recordRef(tester, path, kUri);

    await showHistory(tester, id: 't-uri', absolutePath: path);

    final openButton = find.byIcon(Icons.open_in_new);
    expect(openButton, findsOneWidget,
        reason: 'a sent file with a live original must be openable');

    await tester.tap(openButton);
    await tester.pumpAndSettle();

    expect(openedUris, [kUri],
        reason: 'a content:// original must go through the URI channel');
    // The recorded path was never a thing that could be opened.
    expect(File(path).existsSync(), isFalse);

    await unmount(tester);
  });

  // ---- 2. a sent file whose original is a real path -------------------------
  testWidgets(
      '2. sent file with a real-path original opens the original path, not the '
      'deleted staging copy', (tester) async {
    final path = staged('notes.txt');
    const original = '/storage/emulated/0/Documents/notes.txt';
    expect(File(path).existsSync(), isFalse);
    existingPaths.add(original);
    await recordRef(tester, path, original);

    // The history verdict for this row: reachable, judged by the original.
    final availability = await FileAvailabilityResolver.resolve(
      originalRef: (await lookupRef(tester, path))!.value,
      stagedPath: path,
    );
    expect(availability, FileAvailability.accessible);

    final openedPaths = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileTreeView(
          nodes: [fileNode(path)],
          onOpenFile: openedPaths.add,
          availabilityByPath: {path: availability},
          openRefByPath: {path: const OriginalRef(original)},
        ),
      ),
    ));

    expect(find.byIcon(Icons.open_in_new), findsOneWidget,
        reason: 'a reachable real-path original must be openable');

    await tester.tap(find.byIcon(Icons.open_in_new));
    await tester.pumpAndSettle();

    expect(openedPaths, [original],
        reason: 'open must target the real original');
    expect(openedPaths.single, isNot(path),
        reason: 'the deleted staging copy must never be the open target');
  });

  // ---- 3. no surviving original -> no button --------------------------------
  testWidgets(
      '3. sent file with no surviving original (stagedCopyCleaned) has no Open '
      'button', (tester) async {
    final path = staged('legacy.bin');
    // No OriginalRefStore entry at all: a pre-WP-R6 row.
    expect(await lookupRef(tester, path), isNull);

    await showHistory(tester, id: 't-none', absolutePath: path);

    expect(find.text(stagedCopyCleanedMessage), findsOneWidget,
        reason: 'the row should read as a cleaned copy, not a missing file');
    expect(find.byIcon(Icons.open_in_new), findsNothing,
        reason: 'there is nothing to open, so there must be no button');

    await unmount(tester);
  });

  // ---- 4. a received file is unchanged -------------------------------------
  testWidgets('4. received file whose path exists still opens by that path',
      (tester) async {
    final downloads = Directory('${tempRoot.path}/Downloads')
      ..createSync(recursive: true);
    final received = '${downloads.path}/report.pdf';
    File(received).writeAsStringSync('hello');
    existingPaths.add(received);
    // No original reference: the recorded path *is* the file.
    expect(await lookupRef(tester, received), isNull);

    // The row renders its Open button through the real page.
    await showHistory(tester,
        id: 't-recv', absolutePath: received, direction: 'receive');
    expect(find.byIcon(Icons.open_in_new), findsOneWidget,
        reason: 'received files keep their existing Open button');

    // And the target is the recorded path, with no reference map involved.
    final openedPaths = <String>[];
    final openedRefs = <OriginalRef>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileTreeView(
          nodes: [fileNode(received)],
          onOpenFile: openedPaths.add,
          onOpenRef: (ref) async => openedRefs.add(ref),
          availabilityByPath: const {
            // A received file resolves to accessible with no original ref.
          },
        ),
      ),
    ));
    // With no availability verdict the default is exists-on-disk, and the file
    // does exist, so the button is there and it opens that same path.
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    await tester.tap(find.byIcon(Icons.open_in_new));
    await tester.pumpAndSettle();

    expect(openedPaths, [received]);
    expect(openedRefs, isEmpty, reason: 'received files are never opened as URIs');

    await unmount(tester);
  });

  // ---- 5. send preparation: default behaviour is byte-for-byte the same ----
  testWidgets(
      '5. send preparation default is unchanged: Open only when the file '
      'exists, and a recorded path opens by path', (tester) async {
    final present = '${tempRoot.path}/pending-present.bin';
    final absent = '${tempRoot.path}/pending-absent.bin';
    File(present).writeAsStringSync('x');

    final opened = <String>[];
    // No availabilityByPath, no openRefByPath, no onOpenRef — exactly how
    // send_preparation_page.dart constructs the widget.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileTreeView(
          nodes: [fileNode(present), fileNode(absent)],
          onOpenFile: opened.add,
        ),
      ),
    ));

    // Only the file that is actually on disk gets a button.
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    await tester.tap(find.byIcon(Icons.open_in_new));
    expect(opened, [present]);

    // A recorded reference alone must not resurrect a button for a file that
    // does not exist: a caller that passes a ref map without an accessible
    // verdict is treated as "not known reachable", never as "open me".
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileTreeView(
          nodes: [fileNode(absent)],
          onOpenFile: opened.add,
          openRefByPath: {absent: const OriginalRef('/nowhere/gone.bin')},
          onOpenRef: (_) async {},
        ),
      ),
    ));
    expect(find.byIcon(Icons.open_in_new), findsNothing,
        reason: 'a reference without an accessible verdict opens nothing');
  });

  // ---- 6. a refused or throwing URI open is reported ------------------------
  testWidgets(
      '6. a URI open that is refused or throws surfaces an error instead of '
      'silently doing nothing', (tester) async {
    final path = staged('boom.bin');
    // The document is still granted for *reading* (so the button is offered),
    // but the provider refuses to hand it to a viewer.
    const refused = 'content://provider/refuses';
    reachableUris.add(refused);
    await recordRef(tester, path, refused);

    await showHistory(tester, id: 't-fail', absolutePath: path);
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);

    // (a) the provider answers "not opened" -> an honest message.
    await tester.tap(find.byIcon(Icons.open_in_new));
    await tester.pumpAndSettle();
    expect(openedUris, [refused]);
    expect(find.textContaining('Could not open file'), findsOneWidget,
        reason: 'a refused URI open must be reported, not swallowed');

    await unmount(tester);

    // (b) the channel itself throws -> still an honest message, and no crash.
    ContentUriChannel.open = (uri) async {
      openedUris.add(uri);
      throw StateError('channel died');
    };
    final throwing = staged('boom2.bin');
    const throwingUri = 'content://provider/throws';
    reachableUris.add(throwingUri);
    await recordRef(tester, throwing, throwingUri);

    await showHistory(tester, id: 't-throw', absolutePath: throwing);
    await tester.tap(find.byIcon(Icons.open_in_new));
    await tester.pumpAndSettle();

    expect(openedUris.last, throwingUri);
    expect(tester.takeException(), isNull, reason: 'must not crash');
    expect(find.textContaining('Could not open file'), findsOneWidget,
        reason: 'a throwing URI open must be reported, not swallowed');
  });
}
