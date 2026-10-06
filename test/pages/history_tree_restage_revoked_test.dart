// WP-R15, brief test 4: a grant that was revoked, or a tree that can no longer
// be read, gives a SPECIFIC reason and starts no transfer at all.
//
// The grant is probed before anything is copied, so a folder whose permission
// was revoked costs one probe and an honest message — never a half-copied tree
// and never a `resume_transfer` request the daemon would have to refuse.

import 'package:flutter_test/flutter_test.dart';

import '../support/tree_restage_harness.dart';

void main() {
  late TreeRestageHarness h;

  setUp(() {
    setUpTreeRestage();
    h = TreeRestageHarness();
  });

  tearDown(() => tearDownTreeRestage(h.tempRoot));

  testWidgets('a revoked grant gives a specific reason and makes NO request',
      (tester) async {
    final dead = h.session(1);
    await h.recordTree('$dead/photos');

    final stagedCalls = <String>[];
    h.mockTree(readable: false, stagedCalls: stagedCalls);

    final resumes = await h.tapResend(tester,
        id: 't-tree-revoked', files: h.treeRows('$dead/photos'));

    expect(resumes, isEmpty,
        reason: 'no transfer may be started when the tree cannot be reached');
    expect(stagedCalls, isEmpty,
        reason: 'the grant is probed first, so nothing is copied at all');
    expect(find.textContaining('Cannot resume'), findsOneWidget);
    expect(find.textContaining('permission'), findsWidgets,
        reason: 'the reason must name the specific cause, not just "failed"');
    expect(find.textContaining('Nothing was sent'), findsOneWidget);
  });
}
