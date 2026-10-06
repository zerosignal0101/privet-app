# WP-R11 — on-device verification checklist

## What could not be done in this environment, and why

The task asked for on-device raw evidence (the failing record's
`get_history_detail` JSON, whether those paths existed at the time, the source
path actually fed to the daemon, and the engine's own failure log). Three
independent blockers made that impossible **without changing something the brief
forbids changing**, so it was not attempted and is not claimed here:

1. **No `adb install` was permitted**, so only the already-installed build could
   be driven — and that build is **release** (`flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA
   ALLOW_BACKUP ]`, no `DEBUGGABLE`). `run-as app.privet.privet_app` fails with
   `package not debuggable`, so the app's private dir, its history database and
   its IPC socket (`filesDir/privet/privet.sock`) are unreadable.
2. **No root**: `adb root` → `adbd cannot run as root in production builds`.
3. **The on-device daemon cannot log.** On Android the daemon is an embedded
   thread reached through JNI (`PrivetDaemonNative.privetdRun`) and installs
   **no tracing subscriber** — `privet-daemon/src/android_bridge.rs:36-41`
   states that an app's native stderr goes to `/dev/null` and that "both
   `eprintln` and `tracing::error!` would be invisible in logcat". Logcat for the
   app's PID was readable and contained no daemon output at all. So the
   "engine's own log line for the failure" **cannot exist on Android today**,
   with or without root.

Because of (3) the engine-side evidence in this task was gathered against the
**same engine on the host**, where `privetd` does install a subscriber — see
`wp-r11-root-cause.md` and the `wp-r11-repro-*` artifacts. The device steps below
are what remains to be run once the merged APK is installed.

## Steps to run after the merged install

Device: the Xiaomi `haotian` (`xiaomiv4.voidspace.cn:5745`), where
`app.privet.privet_app` is installed. A second privet device is needed as the
receiver.

### 1. Before the fix — reproduce

1. On the sender: History is empty for a fresh install; send a file picked through
   the SAF picker to the paired receiver and let it complete.
2. Note the history row, then leave the app: the staging copy under
   `<cacheDir>/privet/send-cache/<session>/` is deleted by design on the
   terminal event.
3. History → that record → **Resend**.
   - **Expected on the pre-fix build:** the transfer fails and the tile shows
     `Transfer failed` / `io`.
   - **Expected on the fixed build:** the Send preparation page opens with the
     file listed, seeded from the original reference.

### 2. After the fix — the positive case

1. Send a SAF-picked file to the receiver; let it complete.
2. History → the record → **Resend** → the prepare page opens showing the file.
3. Send. The app must make a **new** staging copy for this transfer and the
   receiver must get the file again.
4. **Byte-identical check on the receiver** (this is the acceptance criterion):

   ```
   # on the receiver, for the file just received
   sha256sum <received-file>
   # on the sender, for the originally picked file
   sha256sum <original-file>
   ```

   The two digests must match. (On the host the same assertion was run and is
   recorded in `wp-r11-root-cause.md`.)

5. **No leak:** after the resent transfer reaches a terminal state, the new
   staging copy must be gone from
   `<cacheDir>/privet/send-cache/<new-session>/`.

### 3. After the fix — the refusal case (must NOT attempt a transfer)

1. Revoke the document's grant to Privet, or delete/move the original file in
   the provider that owns it.
2. History → the same record → **Resend**.
3. **Expected:** a message naming the file and the reason
   ("no longer has permission to read this document" / "no longer at <path>"),
   **and no transfer is started** — no new history row, no failed tile.

### 4. Guardrail spot-check

No `content://…` string may ever be handed to the daemon. The automated coverage
for this is in `test/pages/history_resend_test.dart`
(`URI guardrail`, plus `the send notifier refuses a URI root path before any
request`, which asserts no `send` request is issued). On device, the observable
equivalent is that a resend never shows a bare `io`.

## Screenshots / logs to attach when this is run

- the pre-fix `Transfer failed / io` tile,
- the post-fix preparation page listing the file,
- the post-fix completed transfer tile,
- the receiver-side `sha256sum` line,
- `adb logcat -d | grep -i privet` for the window of each attempt.
