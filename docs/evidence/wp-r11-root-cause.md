# WP-R11 — Resend on a finished send failed with a bare `io`

## Symptom

History → a sent record → **Resend** → the transfer fails and the UI shows
`Transfer Failed io`.

## Root cause (proven, not inferred)

**Candidate 3 of the three in the brief: the staging copy was already cleaned
up when the resend ran.** The engine was handed a path that no longer existed.

The chain, with the code that proves each link:

1. On Android every outgoing file is staged into the app cache before the daemon
   can read it — the daemon only opens real filesystem paths
   (`PrivetFileChannel.copyContentUri` → `<cacheDir>/privet/send-cache/<session>/<name>`,
   `lib/services/android/content_uri_helper.dart:29`).
2. Those staging copies are **deleted by design** once their transfer is
   terminal: `SendPreparationNotifier.releaseTempFor` on completed / cancelled /
   failed (`lib/providers/send_preparation.dart:115`), driven from
   `ActiveTransfersNotifier._releaseSendTemp` (`lib/providers/transfers.dart:343`),
   which calls `SendCache.deleteIfCachedMany` (`lib/services/android/send_cache.dart:73`).
3. The engine records the path it was *given* — the staging copy — as the history
   row's `absolute_path`. So the history row points at a path that is guaranteed
   to be gone by the time the user looks at it.
4. Resending re-used that recorded path. `ops.rs:269` does
   `std::fs::metadata(p).map_err(crate::CoreError::Io)?`, which becomes
   `error_code() == "io"` (`privet-core/src/error.rs:41`) — a bare `io` carrying
   no path and no reason.

So the report's third candidate is the one that holds: **it is not a scoped-storage
or permission problem, and the engine could not open the path because the path was
not there any more.** Note the pre-fix UI branch for a non-partial resend
(`File(abs).existsSync()` filter) hid most of this behind a `Files not found on
disk` snackbar; the `io` surfaced whenever the daemon was reached with the dead
path — which is exactly what the `partial` branch (`resumeTransfer`) does, and
what `resend_transfer` (`engine.resend_with_id`, which re-reads the stored send
intent's paths) does.

## Reproduction — real daemon, real logs

The app's daemon is **embedded** on Android and installs **no tracing subscriber**
(`privet-daemon/src/android_bridge.rs:36-41` says so explicitly: an app's native
stderr goes to `/dev/null`, "both eprintln and `tracing::error!` would be invisible
in logcat"). On top of that the installed build is release-mode and the device is
not rooted, so `run-as` / the IPC socket / the app's private dir are unreadable and
no `adb install` was permitted for this task.

The failure was therefore reproduced against the **same engine** running on the
host, where `privetd` does install a subscriber and `tracing` reaches stderr.

Steps (two daemons on one host, paired by address, both real):

```
privetd --config repro/a/config.json --ipc repro/a/privet.sock   # RUST_LOG=privet_core=debug,...
privetd --config repro/b/config.json --ipc repro/b/privet.sock
privet --ipc repro/b/… pair 127.0.0.1:47908:47910 --code <code-from-A>
privet --ipc repro/a/… pair 127.0.0.1:47818:47820 --code <code-from-B>   # mutual trust
privet --ipc repro/a/… send --to <B> --via 127.0.0.1 stage/payload.bin
```

Baseline transfer really completed — byte-identical on the receiver:

```
16aaab0d…0a4c9d  b/recv/payload.bin     (received)
16aaab0d…0a4c9d  stage/payload.bin      (source)
# engine log: transfer completed transfer_id=t-00b64a82
```

`get_history_detail` for that transfer — note `absolute_path` is the staging path
the daemon was given (`wp-r11-repro-history-detail.json`):

```json
{ "files": [ { "absolute_path": "/tmp/wpr11/repro/stage/payload.bin",
               "relative_path": "payload.bin", "size": 4096, "status": "completed" } ],
  "status": "completed", "transfer_id": "t-00b64a82" }
```

Then the source was deleted (exactly what `send_cache.dart` does on a terminal
transfer) and the transfer resent:

```
$ ls -l /tmp/wpr11/repro/stage/payload.bin
ls: cannot access '…/stage/payload.bin': No such file or directory
$ privet --ipc repro/a/… resend t-00b64a82
{ "state": "requeued", "transfer_id": "t-00b64a82" }
```

The event stream (`wp-r11-repro-events.txt`) — **this is the reported symptom**:

```json
{"data":{"error_code":"io","part_kept":false,"retryable":false,
         "transfer_id":"t-53b832e8"},"name":"transfer_failed","sequence":10}
```

`error_code: "io"`, and history shows the requeued transfer sitting at
`partial / 0 bytes`.

### The diagnosability gap is real and measured

`wp-r11-repro-daemon-a.log` is the full daemon log at
`RUST_LOG=privet_core=debug,privet_daemon=debug,privet_transfer=debug` for the
whole run. It contains **zero** `ERROR`/`WARN` lines and no line naming the
missing path or the `No such file or directory` reason. The detail that
`error_code` drops is not recoverable from the log on this path at all — it is
dropped before anything is logged.

## Why no engine change was made

The brief allows a minimal, separate engine commit only if genuinely necessary,
and forbids a protocol redesign. Two findings made an engine change the wrong
call here:

- Adding a field to `Event::TransferFailed` is not free here: `privet-cli`
  parses events with strict field handling and is explicitly out of bounds for
  this task, so a new field could break a package I am not allowed to touch.
- The detail the log would have to carry is produced *before* the event is
  built, so the cheapest correct place to make this diagnosable is the app,
  which is where the mistake is actually made: the app now refuses up front, and
  says which file and why.

So the fix makes the failure **preventable and specific** rather than trying to
retro-fit the discarded `io` detail through a protocol change.

## What is fixed

- `lib/services/android/resend_staging.dart` (new) resolves each history file
  from its **original reference** into a path that exists now: a `content://`
  reference is probed first and then **re-staged into a new copy** bound to the
  new transfer (so it is cleaned up on that transfer's terminal event, like any
  other), a real path is used directly, and anything unresolvable is reported
  per file with a specific reason.
- `lib/pages/history_page.dart` wires Resend through that, refuses with a
  per-file reason instead of opening the prepare page with nothing, and refuses
  to `resumeTransfer` when the copy a partial send needs is already gone.
- `lib/providers/send_preparation.dart` refuses a URI root path before any
  request is built.
- `assertSendablePath` / `looksLikeUri` are the explicit guardrail: a
  `content://` string can never reach the daemon.
