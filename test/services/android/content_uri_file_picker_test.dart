import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/android/content_uri_file_picker.dart';
import 'package:privet_app/services/android/original_ref_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for WP-R7: the Android file pick must hand back a *persistable*
/// `content://` reference alongside the staging copy, and that URI — not the
/// cache path — is what history remembers.
///
/// The native half is a real SAF intent plus `takePersistableUriPermission`, so
/// these tests drive the Dart half against a fake `privet/file` channel that
/// returns exactly the shape `PrivetFileChannel.onFilesResult` produces. The
/// restart-survival of the grant itself is a device-level property and is
/// verified by the manual checklist in docs/evidence/wp-r7-device-checklist.txt.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fileChannel = MethodChannel('privet/file');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ContentUriFilePicker.enabledForTesting = true;
  });

  tearDown(() async {
    ContentUriFilePicker.enabledForTesting = false;
    messenger.setMockMethodCallHandler(fileChannel, null);
    await OriginalRefStore.clear();
  });

  /// Serves one canned `pickFiles` reply, asserting the method name.
  void mockPick(Object? reply) {
    messenger.setMockMethodCallHandler(fileChannel, (call) async {
      expect(call.method, 'pickFiles');
      return reply;
    });
  }

  test(
      '1. a picked (staging path, URI) pair is recorded per file, and what gets '
      'recorded is the URI — not the cache path', () async {
    const staged = '/data/user/0/app/cache/privet/send-cache/42/report.pdf';
    const uri =
        'content://com.android.providers.media.documents/document/document%3A42';
    mockPick([
      {'path': staged, 'uri': uri},
    ]);

    final paths = await ContentUriFilePicker.pickAndRecord();

    expect(paths, [staged]);
    final dump = await OriginalRefStore.dump();
    expect(dump.length, 1);
    // Keyed by the staging path (what the daemon records as absolute_path) ...
    expect(dump.keys.single, staged);
    // ... but the value is the original reference, verbatim.
    expect(dump[staged], uri);
    // The two are genuinely different things: a disposable cache path and a
    // document URI. The URI is the one that has to survive a restart.
    expect(dump[staged], isNot(staged));
    expect(dump[staged]!.startsWith('content://'), isTrue);

    final stored = await OriginalRefStore.lookup(staged);
    expect(stored!.isContentUri, isTrue);
    expect(stored.asPath, isNull); // a content URI has no filesystem path
  });

  test(
      '2. a 3-file multi-select records all three, index-aligned with the '
      'selection order', () async {
    const paths0 = '/cache/privet/send-cache/11/a.txt';
    const paths1 = '/cache/privet/send-cache/11/b.txt';
    const paths2 = '/cache/privet/send-cache/11/c.txt';
    mockPick([
      {'path': paths0, 'uri': 'content://p/a'},
      {'path': paths1, 'uri': 'content://p/b'},
      {'path': paths2, 'uri': 'content://p/c'},
    ]);

    final paths = await ContentUriFilePicker.pickAndRecord();

    expect(paths, [paths0, paths1, paths2]);
    final dump = await OriginalRefStore.dump();
    expect(dump.length, 3);
    // Each staging path maps to its own URI, in selection order.
    expect(dump[paths0], 'content://p/a');
    expect(dump[paths1], 'content://p/b');
    expect(dump[paths2], 'content://p/c');
  });

  test(
      '3. a cancelled pick records nothing and does not throw', () async {
    // Empty list — what the native side returns for a cancelled selection.
    mockPick([]);
    expect(await ContentUriFilePicker.pickAndRecord(), isEmpty);
    expect(await OriginalRefStore.dump(), isEmpty);

    // Null reply — a picker that never got as far as answering.
    mockPick(null);
    expect(await ContentUriFilePicker.pickAndRecord(), isEmpty);

    // A native error (e.g. no document provider) is not an error here either.
    messenger.setMockMethodCallHandler(fileChannel, (call) async =>
        throw PlatformException(code: 'SAF_ERROR', message: 'no activity'));
    expect(await ContentUriFilePicker.pickAndRecord(), isEmpty);

    expect(await OriginalRefStore.dump(), isEmpty);
  });

  test(
      '4a. one entry the native side could not stage is skipped and the rest '
      'are still recorded', () async {
    // `PrivetFileChannel.onFilesResult` reports a failed staging copy as a null
    // `path`, so the surviving entries keep their index pairing.
    mockPick([
      {'path': '/cache/ok-1.txt', 'uri': 'content://p/ok1'},
      {'path': null, 'uri': 'content://p/unreadable'},
      {'path': '/cache/ok-2.txt', 'uri': 'content://p/ok2'},
    ]);

    final paths = await ContentUriFilePicker.pickAndRecord();

    expect(paths, ['/cache/ok-1.txt', '/cache/ok-2.txt']);
    final dump = await OriginalRefStore.dump();
    expect(dump.length, 2);
    expect(dump['/cache/ok-1.txt'], 'content://p/ok1');
    expect(dump['/cache/ok-2.txt'], 'content://p/ok2');
  });

  test(
      '4b. an entry with an unusable reference still sends, and the others keep '
      'theirs', () async {
    // A persistable grant a provider refuses is swallowed natively
    // (PrivetFileChannel.persistReadGrant) and reaches Dart as an ordinary
    // pair, so "grant denied" is not a distinct Dart input — see the delivery
    // notes. What Dart can be handed is a pair whose uri is not usable as a
    // reference; that must degrade one history row, not the selection.
    mockPick([
      {'path': '/cache/good.txt', 'uri': 'content://p/good'},
      {'path': '/cache/weird.txt', 'uri': 'relative/not-a-reference'},
      {'path': '/cache/also-good.txt', 'uri': 'content://p/also'},
    ]);

    final paths = await ContentUriFilePicker.pickAndRecord();

    // All three remain sendable: the staging copies are what the daemon reads.
    expect(paths,
        ['/cache/good.txt', '/cache/weird.txt', '/cache/also-good.txt']);
    final dump = await OriginalRefStore.dump();
    expect(dump.length, 2);
    expect(dump['/cache/good.txt'], 'content://p/good');
    expect(dump['/cache/also-good.txt'], 'content://p/also');
    expect(dump.containsKey('/cache/weird.txt'), isFalse);
  });

  test('5. a malformed reply is parsed defensively instead of throwing',
      () async {
    mockPick([
      'not a map',
      {'path': '/cache/no-uri.txt'},
      {'uri': 'content://p/no-path'},
      {'path': '', 'uri': 'content://p/empty-path'},
      {'path': '/cache/empty-uri.txt', 'uri': ''},
      {'path': '/cache/real.txt', 'uri': 'content://p/real'},
    ]);

    final paths = await ContentUriFilePicker.pickAndRecord();

    expect(paths, ['/cache/real.txt']);
    final dump = await OriginalRefStore.dump();
    expect(dump, {'/cache/real.txt': 'content://p/real'});
  });

  test('6. off Android the picker is a no-op rather than an error', () async {
    ContentUriFilePicker.enabledForTesting = false;
    messenger.setMockMethodCallHandler(fileChannel, (call) async {
      fail('the native picker must not be called off Android');
    });

    // The host running this test is not Android, so this is the real path.
    expect(await ContentUriFilePicker.pickAndRecord(), isEmpty);
    expect(await OriginalRefStore.dump(), isEmpty);
  });
}
