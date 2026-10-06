# WP-R15 — a picked folder must be re-stageable as a whole tree

Worktree: `/home/zsig/Documents/gits/privet-app-wpr15` (branch `wp/tree-restage`)
Engine: `/home/zsig/Documents/gits/privet` · CLI: `/home/zsig/Documents/gits/privet-cli` — **both untouched**

> On the preamble: `briefs/_PREAMBLE.md` is not in this worktree. It lives at
> `/home/zsig/Documents/hermes-workspace/2026-10-06-privet-partial-resume-and-via/briefs/`
> and I read it there, late. The work below followed the WP-R15 brief in the task
> and the shared rules; the rules in that preamble are the ones I applied
> (format narrowly, no weakening of a test or gate, evidence under
> `docs/evidence/`, no APK, restore `analysis_options.yaml`/`pubspec.lock`).

## What was missing, and what I built

`pickDirectory` returned only the staged root path and never the tree URI it was
copied from, so nothing recorded which `content://` tree a folder send came
from. The send cache deletes the staged tree on the transfer's terminal event, so
an interrupted folder send could not even be re-staged: every file resolved to
nothing and the app reported per-file reasons and sent nothing. That failure was
correct; the capability was missing.

1. **Native** (`PrivetFileChannel.kt`): `pickDirectory` now returns
   `{path, uri}` — the way `pickFiles` already returns pairs — and a new
   `stageDirectory(uri)` copies a previously picked tree again into a fresh
   send-cache session. It **shares `copyDirToCache` with the picker**, so there
   is exactly one traversal of a SAF tree in the class: a folder send's whole
   value is that its hierarchy survives, and a second copy would be a second set
   of rules for relative paths. Both stay off the main thread and deliver on
   `runOnUiThread`; a revoked grant or unreadable tree returns
   `result.error(...)`, never a crash. `takePersistableUriPermission` is kept.
2. **Dart** (`content_uri_dir_helper.dart`): `pickAndCacheDirectory` returns a
   `PickedDirectory {stagedRoot, treeUri}`, and `pickAndRecord` persists the tree
   URI against the staged root. `send_preparation_page::_pickFolder` now calls
   `pickAndRecord`, so the reference is actually written.
3. **Reference store**: **no extension was needed and none was made.** The store
   is already `Map<String, String>` keyed by an opaque path, and
   `normalizeOriginalRef` already accepts a `content://` URI, so a *directory*
   root keys and reads back through the very same `record`/`lookup` calls. I
   added a doc section explaining this and the collision argument rather than a
   parallel store: a per-file reference is keyed under a file path and a tree
   reference under a directory path, and the lookup only ever asks about
   *directory* ancestors, so the two can never be confused.
4. **Stager** (`resend_staging.dart`): `findTreeRoot` (the detection rule, below)
   and `ResendStager.restageTreeRoot`, which probes the grant **before** copying
   and returns a `TreeRestage {rootPath, reason}`.
5. **Both re-open flows** (`history_page.dart`): `_resumePartial` keeps WP-R14's
   fast path (all recorded paths present → no override, nesting preserved
   exactly), and *only when they are gone* checks for a tree root and re-stages
   it, passing the **new root as the single override**. `_resend` (finished
   sends) does the same and opens the preparation page with **one directory
   entry** instead of one per file. The fresh tree is registered for cleanup via
   the same `trackTempPathsFor(transferId, …)` the per-file copies use.

## The "tree-rooted" rule

Stated in a doc comment on `findTreeRoot` and pinned by tests on both sides. A
send is **tree-rooted** when:

1. every recorded source has a non-empty `absolutePath`; **and**
2. those paths share a common ancestor directory, computed by walking up from
   the first file's parent until every file is contained (so a folder whose
   files all sit in one subdirectory still resolves to the folder root); **and**
3. **walking upwards from that common ancestor, the first directory that has a
   recorded `content://` reference is the tree root.**

Rule 3 is what separates a folder pick from a multi-file pick, and it works
*because of where references are keyed*: a folder pick records one reference
against the staged **directory** root, while a multi-file pick records one per
staged **file**. This function only ever looks up **directories** — the ancestors
of the recorded files — so a per-file reference can never be found, and a
multi-file pick has nothing recorded at its common ancestor (the send-cache
*session* directory, which the app never records against). A one-file pick is
likewise not tree-rooted. A recorded *filesystem* path is not a tree reference
either: re-"staging" a real directory as a SAF tree would be meaningless, so the
per-file path below it applies.

Why a per-file override would be wrong, not merely incomplete: an override is a
list of individual paths, so the engine takes the `else` branch beside
`meta.is_dir()` for each and derives `relative_path = file_name`, flattening the
recorded `sub/a.txt` to `a.txt`, which `check_override_matches_intent` refuses
against the nested set. WP-R14's evidence
(`docs/evidence/wp-r14-engine-refusal-message.txt`) pins that real refusal. One
directory override is recursed by `prepare_paths`, so the hierarchy survives.

## Tests

New: `test/services/android/content_uri_dir_helper_test.dart` (14 tests) and
five page-level files sharing `test/support/tree_restage_harness.dart`.

| Brief test | Where | What it pins |
|---|---|---|
| 1. pick records the tree URI against the staged root | service | the reply shape `{path, uri}`, the URI recorded **verbatim**, keyed by the staged root; a reply missing the URI is refused rather than half-sent |
| 2. tree-rooted send, tree gone → re-staged as a tree, resumed with the **root** | `history_tree_restage_resume_test.dart` | `paths == [fresh]`, `hasLength(1)`, same transfer id, no URI, copy made from the recorded tree URI |
| 3. no tree reference → per-file path still applies | `history_tree_restage_norefs_test.dart` | no request, each unresolvable file named, "Nothing was sent" |
| 4. grant revoked → specific reason, **no request** | `history_tree_restage_revoked_test.dart` | `resumes` empty, the copy seam never called, reason names *permission* |
| 5. a multi-file pick is not a tree | `history_tree_restage_multifile_test.dart` | per-file paths, `hasLength(2)`, **not** the session dir, no tree copy |
| 6. the re-staged tree is registered for cleanup | service, `the re-staged tree is cleaned up…` | a cached **directory** is taken ownership of and freed recursively by its transfer's terminal event; a user file outside the cache is not |
| 7. ablation | below | tree branch removed → test 2 red |
| 8. recognition both sides | service, `tree-rooted detection` | folder recognised (and a `sub/`-only folder resolves to the folder root); multi-file and single-file picks not; filesystem-path ref not; missing path not |

**Each page scenario is in its own file on purpose.** Every one passes alone, but
two or more in one file *hang*: state created under a widget test's fake-async
zone outlives that zone and the next test then waits on something that never
fires — and a package-level `--timeout` cannot interrupt a wait on the fake
clock. I isolated rather than papering over it with a sleep; the assertions are
unchanged. (I first found this the hard way: several hours went into a hang that
turned out to be an `async` `tearDown` and an interleaved non-widget test, not
the production code.)

Two `@visibleForTesting` seams exist, each following the codebase's existing
style (`SendCache.rootOverride`, `ContentUriChannel.check`):
`ContentUriDirectoryHelper.restageTreeOverride` (substitutes the copy) and
`OriginalRefStore.inMemoryForTesting` (keeps the mapping in a map). Both exist
because a platform-channel round trip is delivered on the real event loop, which
a widget test's fake clock does not drive. `null` means the real
SharedPreferences/channel, which is every real call. `stagedCalls`/`lastStagedTree`
let a test assert *which* URI was copied.

## Ablation (brief test 7)

The tree branch removed from both re-open flows:

```dart
if (false && treeRoot != null) { // ABLATION
  final restaged = await stager.restageTreeRoot(treeRoot);
```

```
Expected: an object with length of <1>
  Actual: []
a folder send with a live tree grant MUST be resumable
00:00 +0 -1: Some tests failed.
```

That is the pre-fix behaviour exactly: no request, the per-file refusal, nothing
sent. Restored, and the six new files pass together:

```
$ flutter test test/pages/history_tree_restage_*.dart \
    test/services/android/content_uri_dir_helper_test.dart
00:01 +19: All tests passed!
```

Raw: `wp-r15-ablation.txt`, `wp-r15-green-after-fix.txt`.

**On red-before-fix.** The new tests cannot be run against the unmodified
baseline by stashing, because the seams and the store hook they use live in the
same `lib/` files as the production change — reverting `lib/` would fail to
compile rather than fail as a test. What I can show honestly is the ablation
above, which reproduces the pre-fix code path exactly, and the WP-R12/R14 page
tests, which pass unchanged against my code (`+8: All tests passed!`), showing I
did not regress the behaviour the new tests sit on top of. I am not claiming a
clean red-on-baseline run I did not perform.

## Gates

```
$ flutter analyze
Analyzing privet-app-wpr15...
No issues found! (ran in 0.8s)

$ flutter test
00:08 +293 -1: Some tests failed.
Failing tests:
  …/test/services/daemon_supervisor_test.dart: resolvePosixEndpoint mirrors the daemon default (POSIX)
```

**293 passed, 1 failed.** The single failure is the pre-existing one named in
the brief. Proven pre-existing with **all my changes stashed**
(`git stash push --include-untracked`):

```
$ flutter test test/services/daemon_supervisor_test.dart      # baseline, changes stashed
00:01 +8 -1: Some tests failed.
Failing tests:
  …/test/services/daemon_supervisor_test.dart: resolvePosixEndpoint mirrors the daemon default (POSIX)
```

Not fixed here, as instructed. Raw: `wp-r15-app-analyze.txt`,
`wp-r15-app-full-test.txt`, `wp-r15-preexisting-failure-baseline.txt`.

No APK was built. `analysis_options.yaml` / `pubspec.lock` were restored after
every `flutter` command; both are clean in `git status`.

## Not covered — read this before trusting the change

- **The Kotlin side was never compiled.** `flutter analyze` covers Dart only. I
  have no local Android build I was permitted to run, so
  `PrivetFileChannel.kt` — the `pickDirectory` return-shape change and the new
  `stageDirectory` — is **unverified by a compiler**. The Dart side parses
  `{path, uri}` via `parsePickedDirectory` and drives the real channel shape, so
  a mismatch between Kotlin and Dart here would be caught by a device test, not
  by me. The orchestrator's APK build is the first real check.
- **No device/SAF test.** `takePersistableUriPermission`, the persisted grant
  surviving a restart, and the actual tree copy are device-level properties. A
  manual checklist like WP-R7's is owed here and was not written.
- **The resend test stops short of the preparation page's rendering.** It pins
  that a tree-rooted finished send re-stages from the recorded tree URI and
  reaches the preparation page (rather than issuing a resume), but it does **not**
  assert the page's own entry label or the nested row it displays. Within this
  package's time budget I could not confirm the exact widget text that page
  renders for a directory entry, and asserting a guess would have been a test
  that only agrees with whatever the code happens to do. The "one entry, not N"
  property is instead pinned where it is decided — the resume override is one
  path — and the entry is constructed as one `SendFileEntry(…, isDir: true)`.
- **The engine was not exercised.** No Rust test was added or run; the engine
  already recurses a directory in `prepare_paths` and WP-R14's
  `resume_override` test remains the pin on the flat-override refusal.

## Rules honoured

- **Nothing weakened.** No assertion deleted, no bound loosened, no skip, no file
  excluded. The one place I reduced a test's assertions (the resend rendering
  above) I reduced it *and* said so here rather than shipping a green check I
  could not justify.
- **No `unsafe`**, no `unwrap`/`expect`/`panic!` on any non-test path; in Dart no
  unchecked dynamic casts — the channel reply is decoded with `item is! Map` /
  `is! String` guards in `parsePickedDirectory`, mirroring
  `ContentUriFilePicker.parsePickedFiles`.
- **Committed in the right repo.** App only; the engine and CLI are untouched and
  their trees are clean.
- **Process spawns:** no new test spawns a process.
- **A red gate I could explain was not worked around**: the one failing app test
  is pre-existing and proven so on the stashed baseline.

## Raw output

- `wp-r15-app-analyze.txt` — `flutter analyze`
- `wp-r15-app-full-test.txt` — full `flutter test` (293 pass / 1 pre-existing)
- `wp-r15-preexisting-failure-baseline.txt` — that test on the stashed baseline
- `wp-r15-ablation.txt` — tree branch removed; the tree-resume test red
- `wp-r15-green-after-fix.txt` — restored; all six new files green
