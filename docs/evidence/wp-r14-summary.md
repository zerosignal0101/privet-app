# WP-R14 — a directory-rooted send must still resume (no regression)

Worktree: `/home/zsig/Documents/gits/privet-app-wpr12` (branch `wp/partial-resume`)
Engine: `/home/zsig/Documents/gits/privet` · CLI: `/home/zsig/Documents/gits/privet-cli` (untouched)

> Note on the preamble: `briefs/_PREAMBLE.md` does not exist in this worktree
> (`glob **/_PREAMBLE.md` over `/home/zsig/Documents/gits` found nothing), so I
> worked from the WP-R14 brief text plus WP-R12's committed state.

## What I changed and why

WP-R12 made `_resumePartial` resolve **every** recorded file through
`ResendStager` and pass the resolved **per-file** paths as the resume override.
That is right for a file-rooted send whose staging copy is gone. It regressed a
send rooted at a **directory**, which the app supports (`send_preparation_page.dart`
`_pickFolder` → a cached tree; the engine recurses it in `prepare_paths`):

- A directory-rooted send records **nested** relative paths, because `prepare_dir`
  walks the tree — the intent's file set is `sub/a.txt`, `b.txt`.
- An override is a list of individual paths, so `prepare_paths` takes the `else`
  branch beside `meta.is_dir()` for each one and derives `relative_path =
  file_name`. The resolved set comes back **flat** — `a.txt`, `b.txt` — and
  `check_override_matches_intent` refuses it.

**The fix, as decided (no design substituted).** `_resumePartial` now prefers
the recorded paths and only builds an override when they are gone:

1. **Fast path.** If every recorded `absolute_path` is still present, call
   `resumeTransfer(id)` with **no** override — the engine re-reads the recorded
   paths, so nesting is preserved and nothing is re-staged. The existence probe
   is `FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound`, **not**
   `File(p).existsSync()`, because a send can be rooted at a directory and
   `existsSync` is false for one.
2. **Fallback.** Only when one or more recorded paths are gone, fall back to
   `ResendStager` and the override, exactly as WP-R12 implemented it: all-or-
   nothing, per-file reasons, `content://` never reaches the daemon, fresh
   copies registered for cleanup under the same transfer id.
3. Both branches keep the same invariant: a resume covers the whole recorded
   file set or nothing is sent at all.
4. The engine is **unchanged**. `check_override_matches_intent` is not loosened
   and the engine does not accept a flat override for a nested send — the
   refusal is what keeps a wrong file set out of a transfer the receiver has
   already partly filled.

The existence check is deliberately **all-or-nothing**: a partial answer is not
usable, because overriding only some of the files would describe a different
file set than the receiver already holds. A `null`/empty recorded path counts as
gone, and a `stat` that throws counts as gone (the stager gets a try).

## Evidence 1 — The regression, reproduced before anything was changed

New app test `directory-rooted send Resume / resumes with the RECORDED paths and
no override when the staged tree is intact, so nested paths are preserved`,
run against the **unmodified WP-R12 `history_page.dart`** (my changes stashed,
only the new test file restored):

```
$ flutter test test/pages/history_partial_resume_test.dart
Expected: false
  Actual: <true>
the recorded paths are all present, so no override may be built: a flat per-file override would be
refused by the engine and the send could never resume

Failing tests:
  .../history_partial_resume_test.dart: directory-rooted send Resume resumes with the RECORDED
  paths and no override when the staged tree is intact, so nested paths are preserved
```

`Actual: <true>` is `params.containsKey('paths')` — i.e. the pre-fix code **did**
build an override for an intact directory-rooted send. That is the regression, as
a failing test rather than an argument. Raw: `wp-r14-red-before-fix.txt`.

## Evidence 2 — The engine pin, and the real refusal message

`privet-core/tests/resume_override.rs::nested_directory_send_refuses_a_flat_per_file_override`
(extended, not rewritten — the three WP-R12 tests are untouched). Two real
engines over real QUIC: a send rooted at a **directory**, cancelled mid-flight,
then resumed with the flat per-file override WP-R12's code would have produced.

```
$ cargo test -p privet-core --test resume_override nested_directory -- --nocapture --test-threads=1
DIR-FLAT-OVERRIDE transfer_id=t-dir-flat-override -> internal: cannot resume t-dir-flat-override:
  the supplied sources include "a.txt", which is not a file of this send
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 3 filtered out
```

Raw: `wp-r14-engine-refusal-message.txt`. The test also asserts the precondition
that the intent really records the nested paths
(`["b.txt", "sub/a.txt"]`), that a refusal changes nothing (`receiver_state`
equality), that the transfer is still `partial`, and that the no-override resume
of that same nested send **succeeds** under the same id with `file_count == 2` —
which is the behaviour the app's fast path depends on.

### A correction to the brief, verified rather than assumed

The brief says the refusal names "the missing `sub/a.txt`". It does not: the
engine names the **flat** path `a.txt`, because
`check_override_matches_intent` runs its "is this supplied file one of the
recorded ones?" loop **before** its "is every recorded file supplied?" loop, and
the flattened `a.txt` trips the first one. My first draft of the test asserted
the brief's phrasing and **failed** against the real engine:

```
the refusal must name the nested path a flat override is missing, got: internal:
  cannot resume t-dir-flat-override: the supplied sources include "a.txt", which
  is not a file of this send
```

I then asserted the real behaviour (`a.txt` is named and is called out as not a
file of this send) instead of the expected wording. This is a diagnostic nicety,
not a correctness problem: the refusal happens before anything is sent either
way, and the test pins the refusal, not the phrasing. `check_override_matches_intent`
was not changed.

## Evidence 3 — App tests

| Test | What it locks in |
|---|---|
| `directory-rooted send Resume / resumes with the RECORDED paths and no override…` | **The regression pin.** Intact tree → one resume request, same transfer id, and `params` carries **no** `paths` key. |
| `directory-rooted send Resume / makes NO request when the staged tree was deleted…` | **Directory-rooted, sources gone** (Android-shaped: the tree was staged and the cache deleted it wholesale) → `resumes` is empty, `Cannot resume` shown, **both** `sub/a.txt` and `b.txt` named, `Nothing was sent` shown. |
| the 4 WP-R12 `partial send Resume` tests | unchanged and still green (below) |
| the 2 `staging copies are adopted…` tests | unchanged and still green |

```
$ flutter test test/pages/history_partial_resume_test.dart
00:01 +8: All tests passed!

$ flutter test test/pages/history_partial_resume_test.dart test/pages/history_resend_test.dart
00:01 +25: All tests passed!
```

Raw: `wp-r14-green-after-fix.txt`, `wp-r14-app-focused-tests.txt`.

**What the user sees for an unresumable directory-rooted send:** a snackbar
reading `Cannot resume — <one line per file, each naming the file and the
specific cause> / Nothing was sent. This send was interrupted and its temporary
copy was cleaned up; pick the file again to resume it.` No request is issued, so
it cannot become a failed transfer, and the receiver's partial state is untouched.

## Evidence 4 — Ablation

The fast path removed — i.e. the always-override behaviour WP-R12 shipped:

```dart
if (false && _allRecordedPathsPresent(sources)) {   // ABLATION
  await _issueResume(context, service, record.transferId, paths: null);
  return;
}
```

```
$ flutter test test/pages/history_partial_resume_test.dart --plain-name "directory-rooted send Resume"
Expected: false
  Actual: <true>
the recorded paths are all present, so no override may be built...
00:01 +0 -1: ... [E]
00:01 +1 -1: Some tests failed.
```

Raw: `wp-r14-ablation.txt`. The override the ablated code produces is exactly
the flat per-file list that `wp-r14-engine-refusal-message.txt` shows the engine
refusing. Restored, and re-run: `00:01 +8: All tests passed!`
(`wp-r14-green-after-fix.txt`).

The "sources gone" test stays green under ablation — it is a guard against the
code being too permissive, not a discriminator. I am not claiming otherwise.

## Evidence 5 — Gates

### Engine

```
$ cargo test -p privet-ipc -p privet-core -p privet-daemon --lib
test result: ok. 31 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out   (privet-core)
test result: ok. 10 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out   (privet-ipc)
test result: ok.  5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out   (privet-daemon)

$ cargo test -p privet-core --test resume_override -- --test-threads=1
test nested_directory_send_refuses_a_flat_per_file_override ... ok
test resume_with_override_completes_same_transfer_from_fresh_source ... ok
test resume_without_override_after_source_gone_fails_with_bare_io ... ok
test structurally_mismatching_override_is_refused_and_changes_nothing ... ok
test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

Raw: `wp-r14-engine-lib-gate.txt`, `wp-r14-engine-resume-override-gate.txt`.

### App

```
$ flutter analyze
Analyzing privet-app-wpr12...
No issues found! (ran in 0.8s)

$ flutter test
00:08 +266 -1: Some tests failed.
Failing tests:
  .../test/services/daemon_supervisor_test.dart: resolvePosixEndpoint mirrors the daemon default (POSIX)
```

**266 passed, 1 failed.** The single failure is the pre-existing one named in
the brief. Proof it is pre-existing — with **all my changes stashed**
(`git stash push -u`), the same file fails identically:

```
$ flutter test test/services/daemon_supervisor_test.dart      # baseline, changes stashed
00:01 +8 -1: Some tests failed.
Failing tests:
  .../test/services/daemon_supervisor_test.dart: resolvePosixEndpoint mirrors the daemon default (POSIX)
```

Raw: `wp-r14-app-analyze.txt`, `wp-r14-app-full-test.txt`,
`wp-r14-preexisting-failure-baseline.txt`. Not fixed here, as instructed.

## The Android directory-rooted send: unresumable, and refused on purpose

The brief asks me to say plainly whether a **directory-rooted Android** send can
be re-staged at all today. It cannot, and the evidence is in the app:

- `send_preparation_page.dart::_pickFolder` calls
  `ContentUriDirectoryHelper.pickAndCacheDirectory()` (a SAF
  `ACTION_OPEN_DOCUMENT_TREE` pick) and then only does
  `sendPreparationProvider.notifier.addFiles([root])`. It **never** calls
  `OriginalRefStore.record` for the tree, unlike the per-file path in
  `_pickFiles`, which records `normalizeOriginalRef(f.identifier)` for every
  picked file.
- So the picked tree's `content://` URI is not kept anywhere. `ResendStager`
  resolves a file through `OriginalRefStore.lookup(absolutePath)`; with no
  recorded reference and the staged tree deleted by the send cache, every file
  resolves to nothing and is reported with a per-file reason.

Left as-is, per the brief: such a send is **unresumable but refused**. No
request is made, the user is told exactly which files are gone and that nothing
was sent, and the receiver's partial state is untouched. I did not invent a
mechanism for it. The fix in this package makes the *other* directory-rooted
case — one whose tree is still on disk — resume correctly, which it had stopped
doing.

## Rules honoured

- **Format narrowly.** The engine change is test-only. I ran `rustfmt` on the
  single file `privet-core/tests/resume_override.rs`, never `cargo fmt -p` or
  `--all`, precisely because the baseline tree is not rustfmt-clean. `rustfmt
  --check` on that one file reports **2 hunks, both inside the test I added**;
  after formatting, `git diff -U0` shows **one hunk, 121 insertions, zero
  deletions** — no pre-existing line was touched.
- **No `unsafe`**, no `unwrap`/`expect`/`panic!` on any non-test reachable path.
  The new production code returns values and shows reasons; the one `catch (_)`
  in `_allRecordedPathsPresent` degrades to "gone" rather than propagating. No
  unchecked dynamic casts in Dart. Test-only `unwrap`/`expect`/`panic!` match
  the surrounding engine test file.
- **Committed in the right repo.** Engine test → `../privet`; app code, tests and
  this evidence → this worktree. Both trees left clean.
- **No test weakened.** Nothing was skipped, deleted, or loosened; no bound was
  loosened. One assertion I wrote was *wrong about the engine* (the brief's
  phrasing) — I changed it to assert the real behaviour and documented it in
  Evidence 2 rather than changing the engine to match my test.
- **Process spawns.** No test spawns a process: the app tests drive an
  in-memory transport, and the engine harness is unchanged from WP-R12, whose
  waits are bounded by `tokio::time::timeout` and which shuts the receiver down
  on every path.
- **No red gate worked around.** The one failing app test is pre-existing and
  proven so on the stashed baseline.
- **No APK built.** `analysis_options.yaml` / `pubspec.lock` restored after every
  `flutter` command (both clean in `git status`).
- No CLI change: the app still sends `paths` only when it has an override, which
  the WP-R12 wire field already supports.

## Raw output

- `wp-r14-red-before-fix.txt` — the new app test failing on unmodified WP-R12 code
- `wp-r14-green-after-fix.txt` — the same file green after the fix
- `wp-r14-ablation.txt` — the fast path removed; the directory-rooted test red
- `wp-r14-app-focused-tests.txt` — partial-resume + resend, 25 pass
- `wp-r14-engine-refusal-message.txt` — the real flat-override refusal message
- `wp-r14-engine-lib-gate.txt` — `cargo test -p privet-ipc -p privet-core -p privet-daemon --lib`
- `wp-r14-engine-resume-override-gate.txt` — `cargo test -p privet-core --test resume_override -- --test-threads=1`
- `wp-r14-app-analyze.txt` — `flutter analyze`
- `wp-r14-app-full-test.txt` — full `flutter test`
- `wp-r14-preexisting-failure-baseline.txt` — the failing test on the stashed baseline