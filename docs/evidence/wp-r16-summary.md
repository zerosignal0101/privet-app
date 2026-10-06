# WP-R16 — the Send Files page must judge a device the same way the home page does

Branch `wp/send-page-reachability`, worktree `/home/zsig/Documents/gits/privet-app-wpr16`.
App-only: `../privet` (engine) and `../privet-cli` were not touched.

## 1. The bug, and the two predicates that caused it

The app had two different notions of "can I reach this device", and the two pages
used different ones.

**Home page — before** (`lib/pages/home_page.dart:75-76, 168-190`): discovery *or* an
address probe.

```dart
final onlineFps = ref.watch(onlinePeerFingerprintsProvider);
final reachability = ref.watch(reachabilityProvider);
...
final probe = reachability[tp.deviceFingerprint] ?? unknownReachability;
final broadcasting = onlineFps.contains(tp.deviceFingerprint);
state: broadcasting ? TrustedReachability.online : probe.state,
```

**Send Files page — before** (`lib/pages/send_preparation_page.dart`): discovery only.

```dart
// banner
final selectedPeerOffline = state.peerFingerprint != null &&
    !needsPairing &&
    !onlineFps.contains(state.peerFingerprint);

// _send gate
if (fp != null && !onlineFps.contains(fp) && s.viaIp == null) { /* refuse */ }
```

Side by side, for one device at one moment (Z690, reachable at a remembered
address, not broadcasting):

| | Home page said | Send page said |
|---|---|---|
| discovery | not online | not online |
| address probe (already run by the app) | `Reachable at 10.29.218.79` | *never consulted* |
| resulting verdict | reachable, Send offered | **offline**, send refused |
| rendered as | "Online" / "Reachable at &lt;ip&gt;" | "· offline", `cloud_off` icon, "… is offline — turn it on…" |

Both predicates are literally the same expression on the discovery set, and
`reachabilityProvider` was already the richer answer sitting right next to them.
`unknown` was folded into "offline" by both pages, so silence from discovery was
rendered as a positive claim of failure.

## 2. What changed, and why

### `lib/providers/peers.dart` — one verdict, in one place

* **`PeerReachVerdict` + `peerVerdictFor(...)` + `peerReachVerdictProvider`**: the
  composed answer for one fingerprint, from the two raw inputs (the probe map and
  the online set). Discovery outranks a probe (a beacon needs no address and the
  remembered address may be stale); otherwise the probe's verdict stands; no probe
  at all is `unknown`. `isUnreachable` is true for exactly one state —
  `unreachable` — so "offline" can only be said by a probe that actually asked.
* **`ReachabilityNotifier.probePeer(peer, {required bool isOnline})`**: a *single*
  bounded probe for one device, so the send page can learn about its recipient
  without a timer, a subscription or a polling loop. It writes into the same
  `reachabilityProvider` the home page reads, so the two pages cannot drift.
  No-op when the device is broadcasting, has no remembered address, or already
  has a verdict.
* **Per-fingerprint probe tokens** replace the old single `int _generation`.
  This was load-bearing, not cosmetic: one global counter meant a send-page probe
  would invalidate the verdicts of devices a *refresh* was probing concurrently,
  and those rows would sit on "Checking…" forever with nothing left to finish
  them. Tokens are now per device, so an eviction only ever affects the device
  that caused it.

### `lib/pages/send_preparation_page.dart`

* The verdict now comes from `peerReachVerdictProvider`; `selectedPeerOffline` is
  `verdict.isUnreachable` rather than `!onlineFps.contains(fp)`.
* **Discovery is loaded on entry** (`_ensureDiscoveryLoadedOnce`). This was a real
  gap I hit and fixed: `peerListProvider` starts empty and is only filled by an
  explicit `refresh()`, which the home page does on its own refresh. Entering Send
  Files directly never loaded it, so a peer list that was never fetched was
  indistinguishable from a device that is not broadcasting — every peer would
  have been called `unknown` and then probed. (The tests caught this: my first run
  of the "discovered device" test failed exactly this way.)
* **One bounded probe on entry** (`_probeSelectedPeerOnce`), only when the verdict
  is `unknown`, the peer is trusted, it has a remembered address, and discovery
  has loaded. Guarded to fire once; no timers, no polling.
* **A reachable peer's probed address is adopted as `via`**
  (`_adoptProbedAddress`) — the address the provider recorded, not a second
  lookup. It never overwrites an address the user already chose, which keeps the
  page's own invariant true: *the address in the box is the address that is sent*.
* **The `_send` gate reads the same provider** and refuses only when the verdict
  is not sendable and no address is pinned. Screen and button cannot disagree,
  because they read the same fact.
* `_RecipientSection` now takes a status *note* instead of a boolean, so the row
  is captioned `reachable` / `checking…` / `offline` / `not checked` — the same
  vocabulary as the home page, with "offline" reserved for a probe that failed.

### Test harness and existing tests

* `test/support/test_daemon.dart`: `list_peers` now has a neutral default
  ("nothing discovered", which is what an isolated daemon reports anyway) and a
  new `resolveNotFoundResponse(id)` helper. Without the default, 21 tests failed
  on `Bad state: unexpected method: list_peers` — the page legitimately asks for
  the peer list now, and those tests were failing on the request rather than on
  the behaviour they are about. `resolve_address` deliberately has **no** default:
  what an address answers is meaningful, so each affected test states its answer.
* 4 existing test files were updated (6 test cases), all mechanically, none
  weakened:
  * 4 tests gained an explicit `resolve_address` → "nobody answered" answer
    (`send_via_address_test.dart` ×2, `send_via_peer_switch_test.dart` shared rig,
    and `send_preparation_pairing_test.dart` gained a `list_peers` case for its
    raw `MemoryTransport`).
  * 2 tests asserted the **old, wrong copy**, which this change is required to
    replace: `send_via_address_test.dart` asserted "not discoverable" (a cause
    the probe never established — now "No answer at 10.29.210.120"), and
    `send_preparation_offline_test.dart` asserted "is offline" for a peer with no
    remembered address, which is `unknown`, not offline (now "has not been heard
    from and no address is remembered"). Both keep every behavioural assertion:
    the daemon is still never reached, and the pinned-address escape hatch is
    still exercised and still asserted via the `via` the daemon received.

## 3. The rule, reviewable: state → on-screen verdict → send behaviour

Every page reads this table from `peerReachVerdictProvider`. The "notice" column
is `_ReachabilityNotice`; the "recipient row" is `_RecipientSection`; the gate is
`_send`.

| `TrustedReachability` | Meaning | Recipient row | Notice | Send gate |
|---|---|---|---|---|
| `online` | broadcasting — a beacon, the strongest signal, needs no address | `&lt;fp&gt;` (no note) | none | **allowed**, no `via` (engine resolves it) |
| `reachable` | the remembered address answered *as this fingerprint* | `&lt;fp&gt;` · reachable | green "Reachable at `&lt;ip&gt;` — sending there." | **allowed**, `via: <that address>` |
| `probing` | one bounded probe in flight | `&lt;fp&gt;` · checking… | orange "Checking `&lt;name&gt;` at `&lt;ip&gt;`…" | refused: "Still checking…" (or allowed if an address is pinned) |
| `unreachable` | a probe asked and got nobody, or a different device | `&lt;fp&gt;` · **offline** + `cloud_off` | orange "No answer at `&lt;ip&gt;` — …" (+ "sending to `&lt;via&gt;` anyway." if pinned) | refused: "…did not answer at `&lt;ip&gt;`…" (or allowed if an address is pinned) |
| `unknown` | nobody has looked — **not** a failure | `&lt;fp&gt;` · not checked | grey "…has not been heard from… That is not the same as being offline…" | refused: "…no address is remembered…" (or allowed if an address is pinned) |

The pinned-address escape hatch is kept everywhere: `via` is the user's explicit
override for beacon-blocked networks, and it outranks a failed probe by design
(pre-existing behaviour, pinned by its own test).

## 4. Tests

`test/pages/send_page_reachability_test.dart` (7 tests, all new):

1. **discovered** → not offline, never probed, send carries **no** `via`.
2. **reachable at a remembered address, not discovered** → not offline, shows
   "Reachable at `&lt;ip&gt;`", and — asserted on what the daemon received —
   `send` carries `via: 10.29.218.79`.
3. **genuinely unreachable** → blocked, message names the address that was tried.
4. **pinned address still overrides an unanswered probe** (the escape hatch).
5. **no address, nothing probed** (`unknown`) → wording is honest, send blocked
   for the real reason.
6. **probes exactly once, never polls** — pumps 10× the probe bound and asserts
   the probe count is still 1, then `pumpAndSettle` (the pending-timer check
   would catch a timer or subscription).
7. **a different device answers the address** → `unreachable`, not "Reachable".

All use the raw `resolve_address` wire captures in `test/support/resolve_fixtures.dart`,
so the fingerprint matched is a fact about a real daemon capture rather than an
arbitrary string.

## 5. Ablation — the tests can fail

I reverted the composed verdict to the **discovery-only** predicate, i.e. the
pre-fix behaviour, changing only `peerVerdictFor` in `lib/providers/peers.dart`:

```dart
// ABLATION (WP-R16): discovery-only, i.e. the pre-fix predicate.
if (onlineFingerprints.contains(fingerprint)) {
  return const PeerReachVerdict(state: TrustedReachability.online);
}
return const PeerReachVerdict(state: TrustedReachability.unknown);
```

`flutter test test/pages/send_page_reachability_test.dart` → **4 of 7 red**
(`docs/evidence/raw/ablation_discovery_only_red.txt`):

```
a device reachable at a remembered address is NOT offline, and the send carries that address as via
a genuinely unreachable device is blocked, and the message says which address was tried
an address that answers as a DIFFERENT device is not treated as this device
the pinned address still overrides an unanswered probe
```

The headline failure is the reported bug reproduced exactly:

```
The following TestFailure was thrown running a test:
Expected: no matching candidates
  Actual: _TextContainingWidgetFinder:<Found 1 widget with text containing offline: [
```

and the unreachable counterpart:

```
Expected: exactly one matching candidate
  Actual: _TextContainingWidgetFinder:<Found 0 widgets with text containing No answer at 10.29.218.79
```

Ablation removed, same command → **All tests passed!** (7/7)
(`docs/evidence/raw/ablation_restored_green.txt`).

## 6. Gates

`flutter analyze` — clean (`docs/evidence/raw/flutter_analyze.txt`):

```
Analyzing privet-app-wpr16...
No issues found! (ran in 1.8s)
```

`flutter test` (full suite, `docs/evidence/raw/full_test_final.txt`):

```
00:18 +281 -1: Some tests failed.
Failing tests:
  test/services/daemon_supervisor_test.dart: resolvePosixEndpoint mirrors the daemon default (POSIX)
```

**That one failure is pre-existing.** Verified on a pristine worktree of the
unmodified HEAD (`940c1da`, `/tmp/r16-baseline`), full suite
(`docs/evidence/raw/baseline_full_test.txt`):

```
274 passed, 1 failed — the same test:
  test/services/daemon_supervisor_test.dart: resolvePosixEndpoint mirrors the daemon default (POSIX)
    Unsupported operation: Cannot modify unmodifiable map
    dart:collection  _UnmodifiableMapMixin.[]=
    test/services/daemon_supervisor_test.dart 180:25
```

Baseline 274 → 281 is exactly my 7 new tests. Not fixed here, as instructed.

Home page must not regress: `home_page_reachability_test.dart`,
`home_page_known_online_test.dart`, `home_page_refresh_test.dart`,
`providers/peers_test.dart` → **12/12 pass**, and `git diff --name-only HEAD` over
those four test files plus `lib/pages/home_page.dart` returns **0 files** — they
are byte-for-byte unchanged.

Other constraints observed: `analysis_options.yaml` / `pubspec.lock` restored after
every `flutter` command (`git status` shows them clean); no APK built; no Rust
involved so no `unsafe` / `unwrap` surface; no test spawns a process (all run over
`MemoryTransport`), and the one test that could have leaked a timer (the probe) is
pinned by an explicit no-poll assertion plus `pumpAndSettle`'s pending-timer check.

## 7. Files changed

```
lib/pages/send_preparation_page.dart          | 339 ++++++++++++++++++----
lib/providers/peers.dart                       | 159 ++++++++++--
test/pages/send_page_reachability_test.dart    |  new (7 tests)
test/pages/send_preparation_offline_test.dart  |  26 +-
test/pages/send_preparation_pairing_test.dart  |   7 +
test/pages/send_via_address_test.dart          |  14 +-
test/pages/send_via_peer_switch_test.dart      |   5 +
test/support/test_daemon.dart                  |  26 ++
```
