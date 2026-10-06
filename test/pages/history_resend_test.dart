// WP-R11: tapping Resend on a finished send must actually send the file again.
//
// The bug this pins down: on Android every outgoing file is staged into the app
// cache before the daemon can read it, and `send_cache.dart` deletes that copy
// once the transfer is terminal. A history row therefore records an
// `absolute_path` that is gone by design, and feeding it back to the daemon
// produced `Event::TransferFailed { error_code: "io" }` — a path that no longer
// exists, reported as a bare "io" with no filename and no reason.
//
// What these tests lock in:
//   1. a send whose original reference is still readable re-stages a NEW copy and
//      sends that — not the vanished old path, and never the `content://` URI;
//   2. an unreadable original is refused up front with a specific reason and
//      **no** `send` request is ever issued (no trial-then-fail);
//   3. no URI string can ever reach the daemon (guardrail, unit + widget);
//   4. the desktop / test-host path (a real file that still exists) is unchanged;
//   5. the partial-send resume path refuses instead of resuming into `io`.
//
// Every probe is injected, so none of this needs a device, a daemon, or SAF.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/history_page.dart';
import 'package:privet_app/pages/send_preparation_page.dart';
import 'package:privet_app/providers/send_preparation.dart';
import 'package:privet_app/services/android/original_ref_store.dart';
import 'package:privet_app/services/android/resend_staging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_daemon.dart';

const String kUri =
    'content://com.android.providers.media.documents/document/77';

Map<String, dynamic> _entry(String id, {String status = 'completed'}) => {
      'transfer_id': id,
      'direction': 'send',
      'peer_device_fingerprint': 'peer-fp-1',
      'peer_name': 'tablet',
      'root_name': 'root',
      'file_count': 1,
      'total_bytes': 4096,
      'status': status,
      'started_ts': 1,
      'finished_ts': 2,
    };

Map<String, dynamic> _detail(String id, String relativePath, String? absolutePath,
        {String status = 'completed'}) =>
    {
      'transfer_id': id,
      'direction': 'send',
      'peer_device_fingerprint': 'peer-fp-1',
      'peer_name': 'tablet',
      'root_name': 'root',
      'status': status,
      'started_ts': 1,
      'finished_ts': 2,
      'files': [
        {
          'relative_path': relativePath,
          'absolute_path': absolutePath,
          'size': 4096,
          'status': 'complete',
        },
      ],
    };

void main() {
  late Directory tempRoot;
  late Set<String> existingPaths;
  late Set<String> reachableUris;
  late Set<String> stageableUris;
  late List<String> stagedFor;
  late List<Map<String, dynamic>> recordedRefs;
  late List<String> probeOrder;

  /// staged path -> the original reference recorded for it, exactly as
  /// `OriginalRefStore` would hold it on a device.
  late Map<String, String> originalRefs;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('privet-wpr11');
    existingPaths = <String>{};
    reachableUris = <String>{};
    stageableUris = <String>{};
    stagedFor = <String>[];
    recordedRefs = <Map<String, dynamic>>[];
    probeOrder = <String>[];
    originalRefs = <String, String>{};
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
  });

  String stagedCopyFor(String uri) =>
      '${tempRoot.path}/privet/send-cache/${stagedFor.length}/'
      '${uri.split('/').last}.pdf';

  /// A stager whose every probe is fake, plus the call log the assertions read.
  ///
  /// `stagedFor` records which URIs were asked for a new copy; the staged path
  /// handed back deliberately lives in the cache (like the real SAF staging) so
  /// the cleanup path sees a cache path exactly as it would on a phone.
  ResendStager fakeStager() => ResendStager(
        lookupRef: (path) async {
          probeOrder.add('lookup:$path');
          return normalizeOriginalRef(path == null ? null : originalRefs[path]);
        },
        probeUri: (uri) async {
          probeOrder.add('probe:$uri');
          return reachableUris.contains(uri);
        },
        fileExists: (path) {
          probeOrder.add('exists:$path');
          return existingPaths.contains(path);
        },
        stageCopy: (uri) async {
          probeOrder.add('stage:$uri');
          stagedFor.add(uri);
          return stageableUris.contains(uri) ? stagedCopyFor(uri) : null;
        },
        recordRef: (staged, ref) async =>
            recordedRefs.add({'staged': staged, 'ref': ref.value}),
        isCachePath: (path) async => path.startsWith('${tempRoot.path}/'),
      );

  // ---------------------------------------------------------------------------
  // 1. a readable original re-stages a NEW copy and sends that
  // ---------------------------------------------------------------------------
  group('ResendStager', () {
    test('a readable content:// original is re-staged, not sent from the '
        'vanished path', () async {
      final stager = ResendStager(
        lookupRef: (_) async => const OriginalRef(kUri),
        probeUri: (_) async => true,
        fileExists: (_) => false, // the old staging copy is gone
        stageCopy: (_) async => '/data/cache/new-session/report.pdf',
        recordRef: (_, _) async {},
      );

      final result = await stager.resolveOne(
        absolutePath: '/data/cache/old-session/report.pdf',
        relativePath: 'report.pdf',
        size: 4096,
      );

      expect(result.isSendable, isTrue);
      expect(result.restaged, isTrue,
          reason: 'the sent path must be a fresh copy, not the recorded one');
      expect(result.path, '/data/cache/new-session/report.pdf');
      expect(result.path, isNot('/data/cache/old-session/report.pdf'));
      expect(result.path, isNot(startsWith('content://')));
    });

    test('the new copy is recorded against its own reference so it is cleaned '
        'up with this transfer', () async {
      final recorded = <String>[];
      final stager = ResendStager(
        lookupRef: (_) async => const OriginalRef(kUri),
        probeUri: (_) async => true,
        fileExists: (_) => false,
        stageCopy: (_) async => '/data/cache/new-2/report.pdf',
        recordRef: (staged, ref) async => recorded.add('$staged -> ${ref.value}'),
      );

      await stager.resolveOne(
        absolutePath: '/data/cache/old/report.pdf',
        relativePath: 'report.pdf',
      );

      expect(recorded, ['/data/cache/new-2/report.pdf -> $kUri'],
          reason: 'without this mapping the new copy leaks and history cannot '
              'explain it');
    });

    test('a real-path original that still exists is sent directly', () async {
      final path = '${tempRoot.path}/Documents/report.pdf';
      final stager = ResendStager(
        lookupRef: (_) async => OriginalRef(path),
        probeUri: (_) async => false,
        fileExists: (p) => p == path,
        stageCopy: (_) async => null,
        recordRef: (_, _) async {},
      );

      final result = await stager.resolveOne(
        absolutePath: '/data/cache/old/report.pdf',
        relativePath: 'report.pdf',
      );

      expect(result.isSendable, isTrue);
      expect(result.path, path);
      expect(result.restaged, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 2. unreadable original => specific refusal, no staging, no transfer
  // ---------------------------------------------------------------------------
  group('ResendStager refuses before any transfer', () {
    test('an unreadable content:// original is refused by name and never '
        'staged', () async {
      final stager = fakeStager();
      final staged = '${tempRoot.path}/privet/send-cache/1/report.pdf';
      originalRefs[staged] = kUri;
      reachableUris.clear(); // permission no longer held

      final result = await stager.resolveOne(
        absolutePath: staged,
        relativePath: 'report.pdf',
      );

      expect(result.isSendable, isFalse);
      expect(result.reason, contains('report.pdf'),
          reason: 'the message must name the file');
      expect(result.reason, contains('permission'),
          reason: 'the message must say why, not just "missing"');
      expect(stagedFor, isEmpty,
          reason: 'an unreadable document must not even be staged');
    });

    test('the document is probed BEFORE anything is staged', () async {
      final stager = fakeStager();
      final staged = '${tempRoot.path}/privet/send-cache/1/report.pdf';
      originalRefs[staged] = kUri;
      reachableUris.add(kUri);
      stageableUris.add(kUri);

      await stager.resolveOne(
        absolutePath: staged,
        relativePath: 'report.pdf',
      );

      expect(probeOrder.indexOf('probe:$kUri'),
          lessThan(probeOrder.indexOf('stage:$kUri')),
          reason: 'readability must be established before the work is done');
    });

    test('a cleaned staging copy with no saved original explains itself',
        () async {
      final stager = ResendStager(
        lookupRef: (_) async => null,
        probeUri: (_) async => false,
        fileExists: (_) => false,
        stageCopy: (_) async => null,
        recordRef: (_, _) async {},
        isCachePath: (_) async => true,
      );

      final result = await stager.resolveOne(
        absolutePath: '/data/cache/old/report.pdf',
        relativePath: 'report.pdf',
      );

      expect(result.isSendable, isFalse);
      expect(result.reason, contains('cleaned up'));
      expect(result.reason, isNot(contains('not found')),
          reason: 'our own cleanup is not the user\'s file being missing');
    });

    test('a vanished non-cache path reports where it looked', () async {
      final stager = ResendStager(
        lookupRef: (_) async => null,
        probeUri: (_) async => false,
        fileExists: (_) => false,
        stageCopy: (_) async => null,
        recordRef: (_, _) async {},
        isCachePath: (_) async => false,
      );

      final result = await stager.resolveOne(
        absolutePath: '/home/zsig/report.pdf',
        relativePath: 'report.pdf',
      );

      expect(result.reason, contains('/home/zsig/report.pdf'));
    });
  });

  // ---------------------------------------------------------------------------
  // 3. guardrail: a URI is never handed to the daemon
  // ---------------------------------------------------------------------------
  group('URI guardrail', () {
    test('looksLikeUri recognises schemes and rejects plain paths', () {
      expect(looksLikeUri('content://media/document/77'), isTrue);
      expect(looksLikeUri('file:///tmp/a.pdf'), isTrue);
      expect(looksLikeUri('/data/cache/report.pdf'), isFalse);
      expect(looksLikeUri('relative/report.pdf'), isFalse);
      expect(looksLikeUri('C:\\Users\\me\\report.pdf'), isFalse,
          reason: 'a Windows drive letter is not a URI scheme');
    });

    test('assertSendablePath throws on a content:// URI', () {
      expect(() => assertSendablePath('content://x/y'), throwsArgumentError);
    });

    test('assertSendablePath accepts real paths', () {
      expect(() => assertSendablePath('/data/cache/report.pdf'), returnsNormally);
    });

    test('a stager that is handed a URI cannot emit that URI as a path', () async {
      // Defensive: even if a recorded path were somehow a URI, it must not come
      // back out as a sendable path.
      final stager = ResendStager(
        lookupRef: (_) async => null,
        probeUri: (_) async => true,
        fileExists: (_) => true,
        stageCopy: (_) async => null,
        recordRef: (_, _) async {},
        isCachePath: (_) async => false,
      );
      Object? caught;
      try {
        await stager.resolveOne(
          absolutePath: 'content://media/document/77',
          relativePath: 'report.pdf',
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isArgumentError);
    });
  });

  // ---------------------------------------------------------------------------
  // 4. desktop / host path is unchanged
  // ---------------------------------------------------------------------------
  group('desktop behaviour', () {
    test('a recorded real file that still exists stays resendable without any '
        'original reference and without staging', () async {
      final path = '${tempRoot.path}/Downloads/report.pdf';
      Directory('${tempRoot.path}/Downloads').createSync(recursive: true);
      File(path).writeAsBytesSync(List<int>.filled(16, 7));
      final stager = ResendStager(
        lookupRef: (_) async => null,
        probeUri: (_) async => false,
        fileExists: (p) => File(p).existsSync(),
        stageCopy: (_) async => null,
        recordRef: (_, _) async {},
      );

      final result = await stager.resolveOne(
        absolutePath: path,
        relativePath: 'report.pdf',
        size: 16,
      );

      expect(result.isSendable, isTrue);
      expect(result.path, path);
      expect(result.restaged, isFalse,
          reason: 'a desktop file is not staged and must not be re-copied');
    });

    test('the send notifier refuses a URI root path before any request',
        () async {
      // The provider-level guard: even a caller that bypassed the stager cannot
      // get a content:// string into a `send` request.
      var sent = false;
      final daemon = await bootTestDaemon((requests) => scriptFromHandlers({
            'send': (id, _) {
              sent = true;
              return okResponse(id, 'transfer_queued',
                  {'transfer_id': 't-new', 'state': 'queued'});
            },
          })(requests));
      addTearDown(daemon.dispose);

      final notifier = daemon.container.read(sendPreparationProvider.notifier);
      notifier.addFileEntry(SendFileEntry(
          path: kUri, relativePath: 'report.pdf', size: 4096));
      notifier.setPeer('peer-fp-1', name: 'tablet');

      final id = await notifier.send();

      expect(id, isNull, reason: 'a URI root path must not produce a transfer');
      expect(sent, isFalse,
          reason: 'no send request may reach the daemon for a URI');
      final state = daemon.container.read(sendPreparationProvider);
      expect(state.error, contains('document reference'));
    });
  });

  // ---------------------------------------------------------------------------
  // 5. widget-level: the Resend button really opens the prep page with a
  //    re-staged copy, and refuses without sending when it cannot
  // ---------------------------------------------------------------------------
  group('HistoryPage Resend button', () {
    /// Boots a one-record history page and taps Resend, returning every `send`
    /// request the app issued (empty when it correctly refused) plus the
    /// container the page was built on.
    Future<ProviderContainer> tapResend(
      WidgetTester tester, {
      required String id,
      required String relativePath,
      required String? absolutePath,
      String status = 'completed',
      void Function(Map<String, dynamic> sendParams)? onSend,
      List<Map<String, dynamic>>? sends,
    }) async {
      final daemon = await bootTestDaemon(scriptFromHandlers({
        'list_history': (rid, _) =>
            okResponse(rid, 'history', [_entry(id, status: status)]),
        'get_history_detail': (rid, params) => okResponse(
            rid,
            'history_detail',
            _detail(params['transfer_id'] as String, relativePath, absolutePath,
                status: status)),
        'send': (rid, params) {
          sends?.add(params);
          onSend?.call(params);
          return okResponse(rid, 'transfer_queued',
              {'transfer_id': 't-new', 'state': 'queued'});
        },
        'list_trusted': (rid, _) => okResponse(rid, 'trusted', []),
        // The prepare page refuses to send to a peer the daemon does not
        // currently see, so the recipient must be discoverable for the test to
        // reach the `send` request at all.
        'list_peers': (rid, _) => okResponse(rid, 'peers', [
              {
                'device_fingerprint': 'peer-fp-1',
                'device_name': 'tablet',
                'state': 'live',
                'last_beacon_ms': 1,
                'candidates': <dynamic>[],
              },
            ]),
        'resume_transfer': (rid, _) {
          sends?.add({'method': 'resume_transfer'});
          return okResponse(rid, 'transfer_queued',
              {'transfer_id': 't-new', 'state': 'queued'});
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
      return daemon.container;
    }

    testWidgets('Resend of a record whose original still exists sends the '
        'ORIGINAL path, not the deleted staging path (the WP-R11 bug)',
        (tester) async {
      // The user's real file, still on disk.
      final original = '${tempRoot.path}/Documents/report.pdf';
      Directory('${tempRoot.path}/Documents').createSync(recursive: true);
      File(original).writeAsBytesSync(List<int>.filled(32, 9));

      // What the daemon recorded: a staging copy that send_cache deleted once
      // the transfer reached its terminal state.
      final dead = '${tempRoot.path}/privet/send-cache/1/report.pdf';
      expect(File(dead).existsSync(), isFalse);

      // ...and the mapping the app persisted so it could find the real file.
      await tester.runAsync(
          () => OriginalRefStore.record(dead, OriginalRef(original)));

      final sends = <Map<String, dynamic>>[];
      final container = await tapResend(tester,
          id: 't-orig',
          relativePath: 'report.pdf',
          absolutePath: dead,
          sends: sends);

      // Before the fix this never happened: every entry was filtered out by
      // File(dead).existsSync(), the user got "Files not found on disk", and no
      // transfer was ever possible.
      expect(find.byType(SendPreparationPage), findsOneWidget,
          reason: 'a resend whose original is alive must be sendable');

      // The source staged for sending is the live original, never the dead path.
      // `rootPaths` is verbatim what `_send` hands to the daemon.
      final prep = container.read(sendPreparationProvider);
      expect(prep.rootPaths, [original],
          reason: 'the daemon must read the file that actually exists');
      expect(prep.rootPaths, isNot(contains(dead)),
          reason: 'the deleted staging path must never reach the daemon');
    });

    testWidgets('a Send pressed on the resend page issues paths the daemon can '
        'actually open', (tester) async {
      final original = '${tempRoot.path}/Documents/data.bin';
      Directory('${tempRoot.path}/Documents').createSync(recursive: true);
      File(original).writeAsBytesSync(List<int>.filled(32, 9));
      final dead = '${tempRoot.path}/privet/send-cache/1/data.bin';
      await tester.runAsync(
          () => OriginalRefStore.record(dead, OriginalRef(original)));

      final sends = <Map<String, dynamic>>[];
      final container = await tapResend(tester,
          id: 't-send',
          relativePath: 'data.bin',
          absolutePath: dead,
          sends: sends);

      // Drive the very same call the Send button makes.
      final notifier =
          container.read(sendPreparationProvider.notifier);
      final id = await notifier.send();

      expect(id, isNotNull, reason: 'the resend must actually queue a transfer');
      final sendCalls = sends.where((s) => s.containsKey('paths')).toList();
      expect(sendCalls, isNotEmpty, reason: 'Send must reach the daemon');
      final paths = (sendCalls.first['paths'] as List).cast<String>();
      expect(paths, [original]);
      expect(paths.every(looksLikeUri), isFalse,
          reason: 'no URI may ever be handed to the daemon');
    });

    testWidgets('Resend of a staged-sent record whose staging copy is gone '
        'does NOT push a prepare page seeded with the dead path',
        (tester) async {
      final dead = '${tempRoot.path}/privet/send-cache/1/report.pdf';
      expect(File(dead).existsSync(), isFalse,
          reason: 'precondition: the staged copy is gone');

      await tapResend(tester,
          id: 't-dead', relativePath: 'report.pdf', absolutePath: dead);

      // The old code pushed SendPreparationPage with the (filtered-out) path or
      // showed "Files not found on disk"; either way nothing sendable is seeded.
      expect(find.byType(SendPreparationPage), findsNothing,
          reason: 'a dead staging path must never seed the prepare page');
    });

    testWidgets('Resend explains why a partially-sent record cannot be '
        'resumed, instead of resuming into a bare io',
        (tester) async {
      final dead = '${tempRoot.path}/privet/send-cache/1/big.bin';
      final sends = <Map<String, dynamic>>[];

      await tapResend(tester,
          id: 't-partial',
          relativePath: 'big.bin',
          absolutePath: dead,
          status: 'partial',
          sends: sends);

      expect(sends.where((s) => s['method'] == 'resume_transfer'), isEmpty,
          reason: 'resuming a transfer whose source is gone can only fail');
      expect(find.textContaining('Cannot resume'), findsOneWidget);
    });
  });
}
