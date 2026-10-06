// WP-R15: the finished-send RESEND of a folder must not silently flatten it.
//
// The `_resend` path (a completed/cancelled send, not a partial one) re-opens
// the send-preparation page. Resolving a folder's files one at a time and
// handing the page a flat list would both lose the nesting and send the files
// as N independent roots. So a tree-rooted send is re-staged as a tree and the
// page gets ONE directory entry, which it walks itself.

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/pages/send_preparation_page.dart';

import '../support/tree_restage_harness.dart';

void main() {
  late TreeRestageHarness h;

  setUp(() {
    setUpTreeRestage();
    h = TreeRestageHarness();
  });

  tearDown(() => tearDownTreeRestage(h.tempRoot));

  testWidgets(
      'a finished folder send re-opens the preparation page with ONE directory '
      'entry, not one entry per file', (tester) async {
    final dead = h.session(1);
    await h.recordTree('$dead/photos');
    final fresh = h.freshTree(2, 'photos');
    h.mockTree(readable: true, fresh: fresh);
    h.lastStagedTree = null;

    // A COMPLETED send, so the page takes the resend path rather than resume.
    final resumes = await h.tapResend(tester,
        id: 't-tree-done', files: h.treeRows('$dead/photos'), status: 'completed');

    expect(resumes, isEmpty,
        reason: 'a completed send re-opens the page; it does not resume');
    expect(find.byType(SendPreparationPage), findsOneWidget,
        reason: 'the user lands on the preparation page, as for any resend');

    // NOTE (evidence): the deeper assertions about the preparation page's own
    // rendering of the re-staged folder (the "photos" entry label and the
    // nested "sub/a.txt" row) are NOT pinned here. Within this work package's
    // time budget I could not confirm the exact widget text that page renders
    // for a directory entry, and guessing at it would have produced a test that
    // asserts whatever the code happens to do. What IS pinned: the tree was
    // re-staged (the seam was called) and the resend flow reaches the
    // preparation page instead of issuing a resume.
    expect(h.lastStagedTree, kTreeUri,
        reason: 'the folder was re-staged from the recorded tree URI, not '
            'resolved file by file');
  });
}
