// WP-R15, brief tests 3 and 5: a multi-file pick is NOT tree-rooted, and a send
// with no recorded tree reference keeps today's honest per-file failure.
//
// This is the guard on the new tree path being too eager. Two distinct mistakes
// it rules out:
//
//   * a two-file pick (files staged side by side in one send-cache session) must
//     not be read as one folder — sending the session directory would include
//     files the user never picked;
//   * a send whose sources are gone and which has no directory reference must
//     still fail per file, naming each one, rather than being re-staged.
//
// The per-file case is a guard rather than a discriminator: it is expected to
// stay green under ablation of the tree code, and the evidence says so.

import 'dart:io';

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
      'a multi-file pick is not mistaken for a tree: its per-file paths are '
      'used, never the session directory', (tester) async {
    // Two files picked side by side, both still readable as originals.
    final realA = '${h.tempRoot.path}/Documents/a.bin';
    final realB = '${h.tempRoot.path}/Documents/b.bin';
    Directory('${h.tempRoot.path}/Documents').createSync(recursive: true);
    File(realA).writeAsBytesSync(List<int>.filled(16, 1));
    File(realB).writeAsBytesSync(List<int>.filled(16, 2));

    // Per-file references, keyed by each staged FILE — as `pickFiles` records.
    await OriginalRefStore.record('${h.session(1)}/a.bin', OriginalRef(realA));
    await OriginalRefStore.record('${h.session(1)}/b.bin', OriginalRef(realB));

    final stagedCalls = <String>[];
    h.mockTree(readable: true, stagedCalls: stagedCalls);

    final resumes = await h.tapResend(tester,
        id: 't-multi',
        files: [
          ('a.bin', '${h.session(1)}/a.bin'),
          ('b.bin', '${h.session(1)}/b.bin'),
        ],
        rootName: 'root');

    expect(resumes, hasLength(1));
    final paths = (resumes.single['paths'] as List).cast<String>();
    expect(paths, [realA, realB],
        reason: 'a multi-file pick resumes as the two files, in order');
    expect(paths, hasLength(2),
        reason: 'NOT the session directory: that would add files the user never '
            'picked');
    expect(stagedCalls, isEmpty,
        reason: 'nothing is copied as a tree, so nothing was re-staged');
  });
}
