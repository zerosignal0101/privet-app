// WP-R15, brief test 2: a tree-rooted send whose tree is gone is re-staged as a
// whole tree and resumed with the ROOT as the single override — one path, not N.
//
// The capability this pins: `pickDirectory` used to return only the staged root
// and never the tree URI, so nothing recorded which `content://` tree a folder
// send came from. Once the send cache deleted the staged tree on the transfer's
// terminal event, an interrupted folder send could not be resumed at all.
//
// Why ONE directory override and not the N files: an override is a list of
// individual paths, so the engine takes the `else` branch beside
// `meta.is_dir()` for each and derives `relative_path = file_name`, flattening
// the recorded `sub/a.txt` to `a.txt` — which `check_override_matches_intent`
// then refuses. A single directory is recursed by `prepare_paths`, so the
// hierarchy the user picked is the hierarchy that is sent.

import 'package:flutter_test/flutter_test.dart';

import '../support/tree_restage_harness.dart';

void main() {
  late TreeRestageHarness h;

  setUp(() {
    setUpTreeRestage();
    h = TreeRestageHarness();
  });

  tearDown(() => tearDownTreeRestage(h.tempRoot));

  testWidgets(
      'a tree-rooted send whose tree is gone is re-staged as a whole tree and '
      'resumed with the ROOT as the override — one path, not N', (tester) async {
    // The original pick's staged tree, deleted by the send cache. Its tree
    // reference survived, so the tree can be copied in again.
    final dead = h.session(1);
    await h.recordTree('$dead/photos');

    final fresh = h.freshTree(2, 'photos');
    final stagedCalls = <String>[];
    h.mockTree(readable: true, fresh: fresh, stagedCalls: stagedCalls);

    final resumes = await h.tapResend(tester,
        id: 't-tree', files: h.treeRows('$dead/photos'));

    expect(resumes, hasLength(1),
        reason: 'a folder send with a live tree grant MUST be resumable');
    final params = resumes.single;
    expect(params['transfer_id'], 't-tree',
        reason: 'same id: the receiver keeps the chunks it already has');

    final paths = (params['paths'] as List).cast<String>();
    // THE point of the package: ONE directory, not the two files.
    expect(paths, [fresh],
        reason: 'a per-file override would be flattened by the engine to '
            'a.txt/b.txt and refused against the recorded nested set');
    expect(params['paths'], hasLength(1));
    expect(paths.every((p) => !p.startsWith('content://')), isTrue,
        reason: 'no content:// URI may ever reach the daemon');
    expect(stagedCalls, [kTreeUri],
        reason: 'the tree is copied in again from the recorded tree URI');
  });
}
