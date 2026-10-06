// WP-R15 test harness: the fixtures and the one-widget-test driver the
// tree re-staging scenarios share.
//
// ### Why each scenario is in its own file
//
// Every scenario here passes in isolation, but two or more of them in one file
// hang: state the page created under a widget test's fake-async zone (the
// daemon's event stream, the ref store's static write chain) can outlive that
// zone, and the *next* test in the same file then waits on something that can
// never complete. Rather than paper over that with a sleep, each scenario gets
// its own file, so every one runs in a fresh isolate. The assertions are
// unchanged — this is isolation, not a weaker test.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/history_page.dart';
import 'package:privet_app/services/android/content_uri_dir_helper.dart';
import 'package:privet_app/services/android/content_uri_helper.dart';
import 'package:privet_app/services/android/original_ref_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_daemon.dart';

/// The `content://` SAF tree a folder pick returns, kept verbatim.
const String kTreeUri =
    'content://com.android.providers.documents/tree/primary%3ADocuments%2Ftree';

Map<String, dynamic> historyEntry(String id,
        {String status = 'partial', String rootName = 'photos'}) =>
    {
      'transfer_id': id,
      'direction': 'send',
      'peer_device_fingerprint': 'peer-fp-1',
      'peer_name': 'tablet',
      'root_name': rootName,
      'file_count': 2,
      'total_bytes': 8192,
      'status': status,
      'started_ts': 1,
      'finished_ts': status == 'partial' ? null : 2,
    };

Map<String, dynamic> historyDetail(String id, List<(String, String?)> files,
        {String status = 'partial', String rootName = 'photos'}) =>
    {
      'transfer_id': id,
      'direction': 'send',
      'peer_device_fingerprint': 'peer-fp-1',
      'peer_name': 'tablet',
      'root_name': rootName,
      'status': status,
      'started_ts': 1,
      'finished_ts': status == 'partial' ? null : 2,
      'files': [
        for (final (rel, abs) in files)
          {
            'relative_path': rel,
            'absolute_path': abs,
            'size': 4096,
            'status': 'failed',
          },
      ],
    };

/// Sets up the temp tree, the platform seams and the store that the scenarios
/// below share. Call from a test file's `setUp`.
class TreeRestageHarness {
  TreeRestageHarness();

  late final Directory tempRoot = Directory.systemTemp.createTempSync('privet-wpr15');

  /// The send-cache root every staged path lives under, so `SendCache` treats a
  /// re-staged tree as a cache path exactly as on a phone.
  /// The tree URI this harness last handed to the copy seam, so a test can
  /// assert the tree was re-staged from the reference the pick recorded.
  String? lastStagedTree;

  String cacheRoot() => '${tempRoot.path}/cache';

  String session(int n) => '${cacheRoot()}/privet/send-cache/$n';

  /// The path a re-stage returns: a fresh session, same folder name, and a real
  /// directory so the preparation page can walk it.
  String freshTree(int sessionIndex, String name) {
    final root = '${session(sessionIndex)}/$name';
    Directory('$root/sub').createSync(recursive: true);
    File('$root/sub/a.txt').writeAsBytesSync(List<int>.filled(4096, 3));
    File('$root/b.txt').writeAsBytesSync(List<int>.filled(4096, 4));
    return root;
  }

  /// The rows a send rooted at [root] records: nested relative paths, each with
  /// its own absolute path — what a folder pick produces.
  List<(String, String?)> treeRows(String root) => [
        ('sub/a.txt', '$root/sub/a.txt'),
        ('b.txt', '$root/b.txt'),
      ];

  /// Records the tree reference the pick would have recorded, against the staged
  /// root of the original send.
  Future<void> recordTree(String root) =>
      OriginalRefStore.record(root, const OriginalRef(kTreeUri));

  /// Substitutes the two platform seams: the grant probe and the tree copy.
  ///
  /// Both are substituted as plain Dart rather than by mocking the `privet/file`
  /// handler, because a platform-channel reply arrives on the real event loop
  /// which a widget test's fake clock does not drive. The production path
  /// (probe -> copy -> record -> override) is unchanged; only the transport is
  /// replaced. The channel's own shape is covered in
  /// `test/services/android/content_uri_dir_helper_test.dart`.
  void mockTree({
    required bool readable,
    String? fresh,
    List<String>? stagedCalls,
  }) {
    ContentUriChannel.check = (uri) async => readable;
    ContentUriDirectoryHelper.restageTreeOverride = (uri) async {
      stagedCalls?.add(uri);
      lastStagedTree = uri;
      if (fresh == null) throw StateError('grant revoked');
      return fresh;
    };
  }

  /// Boots a one-record history page, taps Resend, and returns every resume
  /// request — so a correct refusal shows up as an empty list.
  Future<List<Map<String, dynamic>>> tapResend(
    WidgetTester tester, {
    required String id,
    required List<(String, String?)> files,
    String status = 'partial',
    String rootName = 'photos',
  }) async {
    final resumes = <Map<String, dynamic>>[];
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'list_history': (rid, _) => okResponse(
          rid, 'history', [historyEntry(id, status: status, rootName: rootName)]),
      'get_history_detail': (rid, params) => okResponse(
          rid,
          'history_detail',
          historyDetail(params['transfer_id'] as String, files,
              status: status, rootName: rootName)),
      'list_trusted': (rid, _) => okResponse(rid, 'trusted', []),
      'list_peers': (rid, _) => okResponse(rid, 'peers', []),
      'resume_transfer': (rid, params) {
        resumes.add(params);
        return okResponse(rid, 'transfer_queued',
            {'transfer_id': id, 'state': 'queued'});
      },
    }));
    addTearDown(daemon.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: daemon.container,
      child: const MaterialApp(home: HistoryPage()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('tablet'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Resend'));
    await tester.pumpAndSettle();
    return resumes;
  }
}

/// The `setUp` body every tree re-staging scenario shares.
void setUpTreeRestage() {
  SharedPreferences.setMockInitialValues({});
  // See `OriginalRefStore.inMemoryForTesting`: the page under test must be able
  // to read back the tree reference this test recorded.
  OriginalRefStore.inMemoryForTesting = <String, String>{};
  ContentUriDirectoryHelper.enabledForTesting = true;
}

/// The matching `tearDown`, kept synchronous on the same reasoning.
void tearDownTreeRestage(Directory tempRoot) {
  ContentUriDirectoryHelper.enabledForTesting = false;
  ContentUriDirectoryHelper.restageTreeOverride = null;
  OriginalRefStore.inMemoryForTesting = null;
  ContentUriChannel.check = checkContentUri;
  if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
}
