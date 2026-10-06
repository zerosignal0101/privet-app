// WP-R12: an interrupted Android send must be resumable.
//
// The bug: on Android every file the user picks is a `content://` document, so
// the send flow stages a copy into the app cache and hands the daemon *that*
// copy. The staging copy is deleted once the transfer reaches a terminal state —
// failure and cancellation included — while the engine records the send's
// absolute paths in `StoredSendIntent.paths` and marks the send `partial`.
// Pressing Resend on such a row routed to `resume_transfer`, which always
// rebuilt its file list from those recorded paths, so the daemon hit a file that
// no longer existed and the resume died as the bare `io` the user saw.
//
// The fix spans the wire contract (`resume_transfer` takes an optional source
// list) and this app (resolve every file from its *original reference* with the
// same `ResendStager` the finished-transfer resend already uses, and pass the
// result as the override).
//
// What these tests lock in:
//   1. a partial send whose recorded staging copy is gone IS resumed, and the
//      request carries the freshly resolved originals — not the dead paths, and
//      never a `content://` URI;
//   2. it is resumed under the SAME transfer id, so the receiver keeps its
//      partial state rather than starting over;
//   3. it is all-or-nothing: if ANY file cannot be resolved, NO request is made
//      and every unresolvable file is named with a specific reason;
//   4. the fresh copies are adopted for cleanup under that same transfer id, so
//      they are freed when the resumed transfer ends instead of leaking.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/history_page.dart';
import 'package:privet_app/providers/send_preparation.dart';
import 'package:privet_app/services/android/original_ref_store.dart';
import 'package:privet_app/services/android/resend_staging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_daemon.dart';

Map<String, dynamic> _entry(String id, {String status = 'partial'}) => {
      'transfer_id': id,
      'direction': 'send',
      'peer_device_fingerprint': 'peer-fp-1',
      'peer_name': 'tablet',
      'root_name': 'root',
      'file_count': 1,
      'total_bytes': 4096,
      'status': status,
      'started_ts': 1,
      'finished_ts': null,
    };

/// [files] is a list of `(relativePath, absolutePath)` pairs — the rows the
/// daemon recorded for the interrupted send.
Map<String, dynamic> _detail(
    String id, List<(String, String?)> files) => {
      'transfer_id': id,
      'direction': 'send',
      'peer_device_fingerprint': 'peer-fp-1',
      'peer_name': 'tablet',
      'root_name': 'root',
      'status': 'partial',
      'started_ts': 1,
      'finished_ts': null,
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

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('privet-wpr12');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  String real(String name) {
    Directory('${tempRoot.path}/Documents').createSync(recursive: true);
    final p = '${tempRoot.path}/Documents/$name';
    File(p).writeAsBytesSync(List<int>.filled(4096, 9));
    return p;
  }

  /// A staging copy that `send_cache.dart` already deleted.
  String dead(String name) => '${tempRoot.path}/privet/send-cache/1/$name';

  /// Boots a one-record partial history page and taps Resend, returning every
  /// request the app issued (so a correct refusal shows up as an empty list).
  Future<List<Map<String, dynamic>>> tapResume(
    WidgetTester tester, {
    required String id,
    required List<(String, String?)> files,
    void Function(Map<String, dynamic> params)? onResume,
  }) async {
    final resumes = <Map<String, dynamic>>[];
    final daemon = await bootTestDaemon(scriptFromHandlers({
      'list_history': (rid, _) =>
          okResponse(rid, 'history', [_entry(id)]),
      'get_history_detail': (rid, params) => okResponse(
          rid, 'history_detail', _detail(params['transfer_id'] as String, files)),
      'list_trusted': (rid, _) => okResponse(rid, 'trusted', []),
      'list_peers': (rid, _) => okResponse(rid, 'peers', []),
      'resume_transfer': (rid, params) {
        resumes.add(params);
        onResume?.call(params);
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

  group('partial send Resume', () {
    testWidgets('resumes a partial send whose staging copy was cleaned up, '
        'using the original reference rather than the dead path',
        (tester) async {
      final original = real('report.pdf');
      final staged = dead('report.pdf');
      expect(File(staged).existsSync(), isFalse,
          reason: 'precondition: the staging copy is gone by design');

      // The mapping the app persisted so it can find the real file again.
      await tester
          .runAsync(() => OriginalRefStore.record(staged, OriginalRef(original)));

      final resumes = await tapResume(tester,
          id: 't-partial', files: [('report.pdf', staged)]);

      // Before the fix this list was empty and the user saw a bare `io`.
      expect(resumes, hasLength(1),
          reason: 'a partial send with a live original MUST be resumable');
      final params = resumes.single;

      // Same transfer id: the receiver keeps the chunks it already has.
      expect(params['transfer_id'], 't-partial');

      final paths = (params['paths'] as List).cast<String>();
      expect(paths, [original],
          reason: 'the daemon must read the file that actually exists');
      expect(paths, isNot(contains(staged)),
          reason: 'the deleted staging path must never reach the daemon');
      expect(paths.every(looksLikeUri), isFalse,
          reason: 'no content:// URI may ever be handed to the daemon');
    });

    testWidgets('makes NO request when a file cannot be resolved, and names '
        'it with a specific reason', (tester) async {
      // A staging copy that is gone AND whose original reference was never
      // saved: nothing can be resolved, so nothing may be attempted.
      final staged = dead('big.bin');

      final resumes = await tapResume(tester,
          id: 't-unresolvable', files: [('big.bin', staged)]);

      expect(resumes, isEmpty,
          reason: 'resuming into the bare `io` is what this fixes; refuse first');
      expect(find.textContaining('Cannot resume'), findsOneWidget);
      expect(find.textContaining('big.bin'), findsWidgets,
          reason: 'the refusal must name the file, not just say "failed"');
      expect(find.textContaining('Nothing was sent'), findsOneWidget,
          reason: 'the user must be told no transfer was attempted');
    });

    testWidgets('is all-or-nothing: one unresolvable file blocks the whole '
        'resume, so a subset is never sent', (tester) async {
      // One file is fine, one is not. The engine refuses a mismatching file set
      // (it would corrupt what the receiver already holds), and so must the app.
      final goodOriginal = real('good.bin');
      final goodStaged = dead('good.bin');
      await tester.runAsync(
          () => OriginalRefStore.record(goodStaged, OriginalRef(goodOriginal)));

      final missingStaged = dead('missing.bin');

      final resumes = await tapResume(tester, id: 't-partial-set', files: [
        ('good.bin', goodStaged),
        ('missing.bin', missingStaged),
      ]);

      expect(resumes, isEmpty,
          reason: 'a resume covers the whole recorded file set or none of it');
      expect(find.textContaining('missing.bin'), findsWidgets,
          reason: 'the refusal must name the unresolvable file');
    });

    testWidgets('resumes every file of a multi-file send when all resolve',
        (tester) async {
      final a = real('a.bin');
      final b = real('b.bin');
      final stagedA = dead('a.bin');
      final stagedB = dead('b.bin');
      await tester.runAsync(() async {
        await OriginalRefStore.record(stagedA, OriginalRef(a));
        await OriginalRefStore.record(stagedB, OriginalRef(b));
      });

      final resumes = await tapResume(tester, id: 't-multi', files: [
        ('a.bin', stagedA),
        ('b.bin', stagedB),
      ]);

      expect(resumes, hasLength(1));
      final paths = (resumes.single['paths'] as List).cast<String>();
      expect(paths, containsAll(<String>[a, b]),
          reason: 'every file of the set must be covered');
      expect(paths, hasLength(2));
    });
  });

  group('staging copies are adopted by the same transfer id', () {
    test('the fresh copies are registered for cleanup under the resumed id',
        () async {
      final notifier =
          ProviderContainer().read(sendPreparationProvider.notifier);

      final registered = await notifier.trackTempPathsFor(
        't-resumed',
        ['/cache/a.bin', '/home/real.bin'],
        // `SendCache.isCachePath` is Android-only, so the probe is injected:
        // only the cache path may be taken ownership of.
        isCachePath: (p) async => p.startsWith('/cache/'),
      );

      expect(registered, ['/cache/a.bin'],
          reason: 'a real user file is not ours to delete');
    });

    test('registration accumulates and dedupes per transfer id', () async {
      final notifier =
          ProviderContainer().read(sendPreparationProvider.notifier);
      Future<bool> cache(String p) async => p.startsWith('/cache/');

      // The original send registers its copy, then the resume re-stages and
      // registers the new one under the SAME id (the receiver's partial state
      // means the id cannot change). Both must be freed together.
      await notifier.trackTempPathsFor('t-x', ['/cache/first.bin'],
          isCachePath: cache);
      final second = await notifier.trackTempPathsFor(
          't-x', ['/cache/second.bin', '/cache/first.bin'],
          isCachePath: cache);

      expect(second, ['/cache/second.bin', '/cache/first.bin'],
          reason: 'both the original and the re-staged copy belong to this id');

      // Releasing is idempotent and must not throw for an unknown id.
      await notifier.releaseTempFor('t-x');
      await notifier.releaseTempFor('t-x');
      await notifier.releaseTempFor('never-registered');
    });
  });
}