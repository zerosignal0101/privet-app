# WP-R13 — the send-to-address box must follow the receiver

**Worktree:** `/home/zsig/Documents/gits/privet-app-wpr13`
**Branch:** `wp/via-follows-peer`
**Scope:** app-only (`lib/providers/send_preparation.dart`,
`lib/pages/send_preparation_page.dart`). Engine and CLI untouched.

## The bug

On the send-preparation page, pressing **Change** to pick a different receiver left the
**Send to address** box showing the previous receiver's address, and the send carried that
address to the daemon — a wrong value crossing the IPC boundary.

## Root cause (verified in this worktree, not taken on trust)

| Location | Finding |
| --- | --- |
| `lib/providers/send_preparation.dart:221-223` | `setPeer` copied only `peerFingerprint`/`peerName`; `viaIp`/`viaError` survived a receiver change. **Confirmed.** |
| `lib/providers/send_preparation.dart:243-245` | `clearPeer` had the **same** defect — `copyWith(clearPeer: true)` leaves `viaIp` set. The brief flagged this only as an invariant to establish; it was broken too. **Confirmed and fixed.** |
| `lib/pages/send_preparation_page.dart:203` | The remount `key: ValueKey('via-${state.peerFingerprint}')` does remount, but the fresh widget re-seeds *from the state*, which still held the stale address. Confirmed by reading `_schedulePrefill`. |
| `lib/pages/send_preparation_page.dart:903-926` | The seeding rule ("a `via` already set wins over remembered") is correct in intent. The state it reads was the bug. **Not changed.** |
| `lib/providers/send_preparation.dart:278` | `send()` passes `state.viaIp` straight through as the `via` override — the stale address is literally what went to the daemon. |

## The fix

Two logic lines, in the provider, where the staleness actually lives:

```dart
void setPeer(String fingerprint, {String? name}) {
  final receiverChanged = state.peerFingerprint != fingerprint;
  state = state.copyWith(
    peerFingerprint: fingerprint,
    peerName: name,
    clearVia: receiverChanged,   // <- new
  );
}

void clearPeer() {
  state = state.copyWith(clearPeer: true, clearVia: true);  // <- new
}
```

`receiverChanged` is what keeps re-selecting the *same* receiver from wiping a half-typed
address — the existing `copyWith` already had a `clearVia` flag, so no new state field was
needed. Everything else in the diff is documentation.

Two comments were added, because the existing comments would otherwise mislead:

* On the `ValueKey` at `send_preparation_page.dart:203` — what the key *still* buys (it
  resets the `_prefilled` latch and the text controller so the box re-seeds per receiver) and
  explicitly that it **cannot** be the fix on its own, since a remount re-seeds from state.
* On `_schedulePrefill` — that its "already-set `via` wins" branch is now safe only because
  `viaIp` is scoped to the selected receiver.

## Invariants established

1. **A different receiver clears the box and the error** — via `setPeer`'s `clearVia`.
   Same receiver re-selected → no clear.
2. **Suggestion list is the current peer's** — `remembered: selectedPeer?.addresses` was
   already fingerprint-scoped and needed no change; it is now pinned by a test rather than
   left as an untested assumption.
3. **`clearPeer` clears the address** — was broken, now fixed.
4. **`initialViaIp` (send-by-address) unaffected** — the page sets the peer first and the
   address second, and `setVia` writes after `setPeer`, so the clearing cannot race it.
5. **One source of truth** — the key keeps the widget from caching a copy that outlives the
   receiver; the provider clearing makes the state honest. Both are documented at the site.

## Tests added

`test/pages/send_via_peer_switch_test.dart` — 8 tests, receiver A (`alpha`) / B (`bravo`):

| Test | What it pins |
| --- | --- |
| switching receiver clears the box and sends no via from A | Box empty for B; **the `send` request carries no `via` key** |
| switching receiver adopts B's own remembered address | B's newest address shown *and* sent, not A's |
| the suggestion chips list the current peer's addresses only | Chips are B's; A's address no longer offered |
| an address typed for A never reaches B, and does not come back | Typed `172.16.0.9` not sent to B; returning to A re-seeds instead of resurrecting it |
| re-selecting the same receiver keeps a half-typed address | `10.0.0` survives `setPeer` of the same fingerprint |
| the send-by-address entry keeps the address the user typed | `initialViaIp` beats both remembered addresses and the clearing rule |
| clearing the receiver clears the address too | `clearPeer` drops `viaIp` |
| a receiver change clears a pending address error as well | A's typo does not leave B's send disabled |

Assertions are on **what the daemon was handed** (`d.sends`), not only on rendered text. In
the headline test the `containsKey('via')` assertion runs *before* the text assertion on
purpose: in the unfixed state the stale `via` also bypasses the page's offline gate
(`send_preparation_page.dart`, `_send`), so the request is genuinely built — and asserting
text first would stop at the cosmetic symptom and never reach the wrong value crossing the
boundary.

Both receivers are put online in the fixtures because `_send` deliberately refuses to send
to an undiscovered peer with no pinned address; without that, B would abort before the
request exists. That gate is correct product behaviour and was left alone.

## Commands and raw output

### 1. Failure demonstrated BEFORE the change

```
$ flutter test test/pages/send_via_peer_switch_test.dart
```

```
00:01 +3 -5: Some tests failed.

Failing tests:
  .../send_via_peer_switch_test.dart: a receiver change clears a pending address error as well
  .../send_via_peer_switch_test.dart: an address typed for A never reaches B, and does not come back
  .../send_via_peer_switch_test.dart: clearing the receiver clears the address too
  .../send_via_peer_switch_test.dart: switching receiver adopts B's own remembered address, not A's
  .../send_via_peer_switch_test.dart: switching receiver clears the box and sends no via from A
```

Full output: `wp-r13-red-before-fix.txt` (3 passed / 5 failed). The failures include:

```
Expected: empty
  Actual: '10.0.0.1'
```

The 3 that passed here (chips, same-receiver, `initialViaIp`) are regression pins that were
already correct — they are meant to stay green.

### 2. Passing AFTER the change

```
$ flutter test test/pages/send_via_peer_switch_test.dart
00:01 +8: All tests passed!
```

Full output: `wp-r13-green-after-fix.txt`.

### 3. Ablation — the clearing removed, tests go red

`setPeer` reverted to `copyWith(peerFingerprint:..., peerName:...)` and `clearPeer` to
`copyWith(clearPeer: true)` — i.e. the exact pre-fix behaviour:

```
$ flutter test test/pages/send_via_peer_switch_test.dart
00:01 +3 -5: Some tests failed.
```

Same 5 tests fail. The decisive one is now at the IPC boundary rather than the rendered text:

```
Expected: false
  Actual: <true>
receiver A's address must never cross the IPC boundary for B
```

and, from the adopt case, the wrong address shown for the wrong device:

```
Expected: '192.168.5.5'
  Actual: '10.0.0.1'
```

Full output: `wp-r13-ablation.txt`. The clearing was then restored and the suite re-run
green (`wp-r13-green-after-fix.txt`), so the ablation is a controlled experiment, not a
permanent state.

### 4. Gates

```
$ flutter analyze
Analyzing privet-app-wpr13...
No issues found! (ran in 1.4s)
```
(`wp-r13-analyze.txt`)

```
$ flutter test
00:07 +266 -1: Some tests failed.

Failing tests:
  .../test/services/daemon_supervisor_test.dart: resolvePosixEndpoint mirrors the daemon default (POSIX)
```
(`wp-r13-full-test.txt`)

**266 passed, 1 failed.** The single failure is the known pre-existing one named in the
brief. Evidence it is pre-existing and not caused by this change: run in a **separate
worktree checked out at the unmodified base commit `9b48db2`**, with none of my changes
present —

```
$ git worktree add /tmp/wp-r13-baseline HEAD --detach
$ flutter test test/services/daemon_supervisor_test.dart
00:01 +8 -1: Some tests failed.

Failing tests:
  .../test/services/daemon_supervisor_test.dart: resolvePosixEndpoint mirrors the daemon default (POSIX)
```

(`wp-r13-baseline-known-failure.txt`). Not fixed here, as instructed.

## Rules compliance

- App-only; engine and CLI not touched.
- No `unsafe`, no `unwrap`/`expect`/`panic`; no unchecked null casts in Dart.
- Committed in the app repo only; tree left clean.
- No gate weakened: no test skipped, no assertion loosened, no file excluded. The only
  non-test logic change is the two lines above. The three tests that were green before the
  change were kept green as explicit regression pins.
- No process-spawning tests added (the harness is an in-memory transport), so no timeout or
  reaping obligation was introduced; every test uses the bounded `_settleFrames` pump
  rather than `pumpAndSettle`.
- `git checkout -- analysis_options.yaml pubspec.lock` run after the `flutter` commands that
  touched them.
- No APK built.

## Files changed

- `lib/providers/send_preparation.dart` — the fix (2 logic lines + docs)
- `lib/pages/send_preparation_page.dart` — comments only
- `test/pages/send_via_peer_switch_test.dart` — new, 8 tests
- `docs/evidence/wp-r13-*.txt` — raw command output