// WP-R15, brief test 3: a send with NO recorded tree reference still takes the
// per-file path and reports per-file reasons.
//
// This keeps today's honest failure intact. Before this package, an interrupted
// folder send could only fail this way; now it can be re-staged when a tree
// reference exists, but a send without one must still degrade to a specific,
// per-file refusal — never to a guessed tree, and never to a subset.

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/android/original_ref_store.dart';

import '../support/tree_restage_harness.dart';

void main() {
  late TreeRestageHarness h;

  setUp(() {
    setUpTreeRestage();
    h = TreeRestageHarness();
  });

  tearDown(() => tearDownTreeRestage(h.tempRoot));

  testWidgets(
      'no recorded tree reference → the per-file path still applies and reports '
      'reasons (keeps today\'s honest failure)', (tester) async {
    // A multi-file pick whose sources are gone. `a.txt` has a recorded
    // reference; `b.txt` never had one. No directory is recorded anywhere, so
    // the send is not tree-rooted.
    await OriginalRefStore.record('${h.session(1)}/a.txt',
        const OriginalRef('content://p/doc/a'));

    final stagedCalls = <String>[];
    h.mockTree(readable: true, stagedCalls: stagedCalls);

    final resumes = await h.tapResend(tester,
        id: 't-norefs',
        files: [
          ('a.txt', '${h.session(1)}/a.txt'),
          ('b.txt', '${h.session(1)}/b.txt'),
        ]);

    expect(stagedCalls, isEmpty,
        reason: 'without a directory reference nothing is copied as a tree');
    expect(resumes, isEmpty,
        reason: 'a file whose original is gone cannot be sent; a subset must '
            'never be sent instead');
    expect(find.textContaining('Cannot resume'), findsOneWidget);
    expect(find.textContaining('b.txt'), findsWidgets,
        reason: 'each unresolvable file is named');
    expect(find.textContaining('Nothing was sent'), findsOneWidget);
  });
}
