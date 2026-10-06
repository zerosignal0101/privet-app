# WP-R12 — an interrupted Android send must be resumable

Worktree: `/home/zsig/Documents/gits/privet-app-wpr12` (branch `wp/partial-resume`)
Engine: `/home/zsig/Documents/gits/privet` · CLI: `/home/zsig/Documents/gits/privet-cli`

## What I changed and why

The reported bug: on Android, for anything picked through a file picker (every
`content://` source), pressing **Resend** on an interrupted send could never send
it again — the user saw a bare `Transfer Failed io`.

**I verified the orchestrator's root cause myself before changing anything**,
at all five cited locations:

| # | Claim | Location | Verified |
|---|---|---|---|
| 1 | Android hands the daemon a staged cache copy, not the `content://` URI | brief's step 1 | ✅ |
| 2 | Terminal states — **including failure and cancellation** — delete staged copies | `lib/providers/transfers.dart` → `_releaseSendTemp` → `send_preparation.dart:116` `releaseTempFor` → `SendCache.deleteIfCachedMany` | ✅ |
| 3 | The engine records the send's absolute paths and marks it `partial` | `privet-core/src/ops.rs:364-369` (`StoredSendIntent.paths`), `ops.rs:472` (`TransferStatus::Partial`) | ✅ |
| 4 | History routes `send`+`partial` to a resume | `lib/pages/history_page.dart:257-262` → `_resumePartial` → `service.resumeTransfer` | ✅ |
| 5 | `resume_send` rebuilds from the recorded paths, so `std::fs::metadata` fails → `CoreError::Io` | `privet-core/src/ops.rs:564-570` → `prepare_paths` → `ops.rs:269` `.map_err(CoreError::Io)` | ✅ |

I also confirmed the wire symptom end to end: `CoreError::Io` maps to
`error_code() == "io"` (`privet-core/src/error.rs:41`), which is exactly the code
the daemon publishes on `TransferFailed` (`privet-daemon/src/backend.rs:341`) and
the GUI renders.

The asymmetry in the brief is real: the **finished**-transfer path was already
fixed to re-resolve files and re-stage them (`lib/services/android/resend_staging.dart`),
and the partial-resume path was never wired to it — and could not be fixed in the
app alone, because `resume_transfer` took only a transfer id and always read the
recorded paths.

**The fix, as decided (no design substituted):**

1. **Engine / IPC** — `ResumeTransfer` gains `paths?: Vec<String>`. Present and
   non-empty ⇒ the engine reads those instead of `StoredSendIntent.paths`. Same
   peer target, same transfer id, nothing else changes. Structurally additive:
   absent/empty keeps today's behaviour exactly. Documented in
   `SPECIFICATIONS/09-daemon-ipc.md` next to the existing `send.via` note.
   `resume_send` is kept as a thin wrapper, so existing callers and the four
   pre-existing `resume_intent` tests are untouched.
2. **Engine validation, strict** — the receiver is already holding a partial
   transfer under this id and will *skip* chunks it trusts, so an override
   describing a different file set would write bytes into a layout the receiver
   already believes. `check_override_matches_intent` refuses a differing
   `root_name`, an unrecorded relative path, a missing recorded path, or a
   differing per-file size — always naming the file that disagrees — **before**
   anything is sent, so a refusal changes nothing.
3. **App** — `_resumePartial` now resolves every file from its **original
   reference** using the existing `ResendStager` (no second stager written) and
   passes the resolved paths as the override. All-or-nothing: if any file cannot
   be resolved, **no request** is made and every unresolvable file is named with
   a specific reason. The stager's `assertSendablePath` guard is re-checked at
   the boundary, so a `content://` string can never reach the daemon.
4. **Cleanup adopted, not leaked** — the fresh copies are registered under the
   **same transfer id** via the new `trackTempPathsFor`, so the existing
   terminal-state cleanup frees them exactly like the originals. The cache cleanup
   itself is deliberately **not** weakened (the cache once grew past 2.6 GB).
5. **CLI** — `Request::ResumeTransfer` is constructed literally, so the field is
   added as `None`. No behaviour change.

### A note on `root_name` validation

`prepare_paths` sets `PreparedSet.root_name` by echoing the `root_name` argument
it is handed (`ops.rs:384`), and `resume_send_with_paths` hands it the recorded
row's root name — so through the public resume path this guard is satisfied by
construction and cannot fire. Rather than leave it untested, the root-name
refusal is covered directly by unit tests on `check_override_matches_intent`
(`ops::resume_override_tests::mismatched_root_name_is_refused_and_named`). The
relative-path and size checks, which *can* differ, are covered both by unit tests
and by the live two-daemon test.

### Scope discipline: a mistake I made and corrected

My first commit ran `cargo fmt -p privet-core`, which rewrote **24 files**. The
preamble warns about exactly this, and the cause was that the baseline tree is
**not** rustfmt-clean: `cargo fmt --check -p privet-core` at pristine HEAD reports
**50 hunks across 13 files**, none of them mine. I reverted that commit
(`git reset --hard HEAD~1`), re-applied my four semantic edits surgically onto
the pristine files, and re-committed. The final engine diff touches exactly 4
modified files + 1 new test file, 5 hunks in `ops.rs`, with no formatting noise.
Evidence: `docs/evidence/baseline-fmt-dirty.txt`.

## Evidence 1 — Reproduction of the old failure (two real daemons, real interrupt)

`privet-core/tests/resume_override.rs::resume_without_override_after_source_gone_fails_with_bare_io`

Two real `Engine`s over real QUIC, a 64 MiB file, the transfer interrupted
mid-flight by a **receiver-side cancel** once the first progress event proves
bytes are flowing, then the recorded source deleted (exactly what the app's send
cache does), then a resume with no override.

```
$ cargo test -p privet-core --test resume_override -- --nocapture --test-threads=1
REPRO transfer_id=t-repro-io resume_without_override -> error_code=io message="io: No such file or directory (os error 2)"
test resume_without_override_after_source_gone_fails_with_bare_io ... ok
```

`error_code=io` with the message `io: No such file or directory (os error 2)` is
the reported `Transfer Failed io`, reproduced — not argued. The same scenario is
also what the engine ablation below reproduces with the plumbing removed.

This test is kept permanently so the no-override contract cannot be broken
silently.

## Evidence 2 — Tests that fail without my change

| Test | File |
|---|---|
| resume whose recorded paths are gone but whose override is supplied | `privet-core/tests/resume_override.rs::resume_with_override_completes_same_transfer_from_fresh_source` |
| a structurally mismatching override is refused | `::structurally_mismatching_override_is_refused_and_changes_nothing` |
| root-name / unknown-file / changed-size / missing-file refusals name the file | `privet-core/src/ops.rs::resume_override_tests::*` (6 unit tests) |
| the app's Resume passes the resolved originals as the override | `test/pages/history_partial_resume_test.dart` (4 widget tests) |
| no request when a file cannot be resolved, asserting the per-file reason | same file |
| fresh copies adopted for cleanup under the same transfer id | same file (2 tests) |

Both directions are covered: the matching override succeeds, a mismatching one is
refused, and a refusal changes nothing (see the `receiver_state` equality
assertions and `assert_still_partial`).

## Evidence 3 — End-to-end two-daemon run

`resume_with_override_completes_same_transfer_from_fresh_source`: real senders and
receiver, mid-flight cancel, source deleted, re-staged at a **new path**, resumed.

```
RESUME-SIGNAL transfer_id=t-resume-override total_bytes=67108864 baseline_bytes=32505856 newly_sent_bytes=34603008 progress_events=4 progress=[32505856, 50331648, 57671680, 67108864]
```

- **Same transfer id** — `outcome.transfer_id == "t-resume-override"`, so the
  receiver's partial state was reused, not restarted.
- **Content equality** — the received 67 108 864 bytes are compared byte-for-byte
  against the original payload (`assert!(received == payload)`).
- **Non-vacuous "less than the whole file crossed the wire"** — the resume opened
  at a **non-zero baseline of 32 505 856 bytes**: the sender's first progress
  event on a resume reports the chunks the receiver already verified and is
  skipping (`privet-transfer/src/sender.rs:431` `baseline_bytes`). The bytes newly
  verified during the resume sum to **34 603 008**, strictly less than the
  67 108 864 total, and the run ends at exactly the full total.

A pre-existing benign warning appears in this test
(`receive history: offer insert failed ... UNIQUE constraint failed`): on resume
the receiver re-offers the same transfer id, whose history row already exists.
It is a `WARN` on a handled path and is unrelated to this change.

## Evidence 4 — Ablation

**Engine** — the override plumbing removed, i.e. the wire field treated as if it
did not exist:

```rust
let override_paths: Option<Vec<std::path::PathBuf>> = None; // ABLATION
```

```
$ cargo test -p privet-core --test resume_override
test resume_with_override_completes_same_transfer_from_fresh_source ... FAILED
test structurally_mismatching_override_is_refused_and_changes_nothing ... FAILED
test resume_without_override_after_source_gone_fails_with_bare_io ... ok
a matching override must let the resume succeed: Io(Os { code: 2, kind: NotFound, message: "No such file or directory" })
the refusal must name the disagreeing file, got: io: No such file or directory (os error 2)
test result: FAILED. 1 passed; 2 failed
```

The e2e fails with **precisely the reported error**. Restored: `3 passed`.

**App** — `lib/pages/history_page.dart` reverted to its pre-fix version (the
`FileSystemEntity.typeSync` existence check and a bare `resumeTransfer`):

```
$ flutter test test/pages/history_partial_resume_test.dart
resumes a partial send whose staging copy was cleaned up ... [E]
  Expected: an object with length of <1>
    Actual: []
   Which: has length of <0>
  a partial send with a live original MUST be resumable
makes NO request when a file cannot be resolved ... [E]
  Expected: exactly one matching candidate
    Actual: _TextContainingWidgetFinder:<Found 0 widgets with text containing Nothing was sent: []>
resumes every file of a multi-file send when all resolve ... [E]
  Expected: an object with length of <1>
    Actual: []
Some tests failed.
```

`Actual: []` — **no resume request was issued at all**, which is the reported bug.
Restored: `All tests passed` (23 with `history_resend_test.dart`).

Note the all-or-nothing test stays green under ablation — it is a guard against
*my* code being too permissive, not a discriminator. The two cleanup-registration
tests also stay green because they cover `send_preparation.dart`, which the
ablation did not touch. I have not claimed otherwise.

## Evidence 5 — Gates

### Engine

```
$ cargo test -p privet-ipc -p privet-core -p privet-daemon --lib
running 31 tests
test result: ok. 31 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
running 10 tests
test result: ok. 10 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
running 5 tests
test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

31 (privet-core, incl. the 6 new `resume_override_tests`) + 10 (privet-ipc) + 5
(privet-daemon). The suite I added:

```
$ cargo test -p privet-core --test resume_override
test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

Pre-existing suite my signature touches, run unchanged:

```
$ cargo test -p privet-core --test resume_intent
test resume_send_not_found_returns_internal ... ok
test resume_send_wrong_direction_error ... ok
test resume_send_not_partial_error ... ok
test resume_send_no_intent_error ... ok
test result: ok. 4 passed; 0 failed
```

### App

```
$ flutter analyze
Analyzing privet-app-wpr12...
No issues found! (ran in 2.3s)

$ flutter test
00:11 +264 -1: Some tests failed.
Failing tests:
  /home/zsig/Documents/gits/privet-app-wpr12/test/services/daemon_supervisor_test.dart: resolvePosixEndpoint mirrors the daemon default (POSIX)
```

**264 passed, 1 failed.** The single failure is the pre-existing one named in the
brief. Proof it is pre-existing — with **all my changes stashed**
(`git stash push -u`), the same file fails identically on the unmodified baseline:

```
=== BASELINE (my changes stashed) ===
00:01 +8 -1: resolvePosixEndpoint mirrors the daemon default (POSIX) [E]
00:01 +8 -1: Some tests failed.
  test/services/daemon_supervisor_test.dart: resolvePosixEndpoint mirrors the daemon default (POSIX)
```

Not fixed here, as instructed.

### CLI

Not gated — the orchestrator owns it. The change is a single `paths: None,` line.

## Rules honoured

- No `unsafe`. No new `unwrap()`/`expect()`/`panic!` on a non-test path; the new
  production code (`check_override_matches_intent`, `recorded_send_files`,
  `resume_send_with_paths`, `trackTempPathsFor`, `_resumePartial`) returns errors
  and shows per-file reasons instead of panicking. Test-only `unwrap()`/`expect()`
  matches the existing test files.
- Formatting scoped: I did **not** run `cargo fmt --all`; the one `cargo fmt -p`
  I ran was reverted in full (see scope discipline above). No `analysis_options.yaml`
  or `pubspec.lock` change is committed — restored after every `flutter` command.
- No test weakened, skipped, or excluded. No bound loosened. No assertion deleted.
  The pre-existing WP-R11 test that pinned the *refusal* behaviour
  (`history_resend_test.dart:538`) still passes unchanged, and still correct: when
  the original reference is genuinely unresolvable, refusing without a request is
  still right.
- No APK built.
- Every test that spawns a process bounds its waits with a hard timeout and
  reaps children: the engine harness shuts the receiver down on every path, and
  the app tests drive an in-memory transport (no process at all).

## Commits

- `../privet` — `3ecd56d` feat(resume): let a resume supply fresh sources for a recorded send; `1dc5ebe` test(resume): print the reproduced bare io and the resume byte signal
- `../privet-cli` — `15c28ea` build: pass paths: None for resume_transfer
- app worktree — see `git log` in this repository.

## Raw output

- `docs/evidence/baseline-fmt-dirty.txt` — `cargo fmt --check` at pristine HEAD
- `docs/evidence/repro-and-e2e.txt` — the reproduction and the e2e byte signal
- `docs/evidence/engine-ablation.txt` — engine ablation, raw
- `docs/evidence/app-ablation.txt` — app ablation, raw
- `docs/evidence/engine-gate.txt` — engine lib gate
- `docs/evidence/app-suite-summary.txt` — app suite counts and the failing test