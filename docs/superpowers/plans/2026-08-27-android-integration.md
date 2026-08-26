# Android Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app run on Android with an **on-device daemon**: bundle a cross-compiled `privetd`, extract + spawn it in the app sandbox, talk to it over a unix socket via a Kotlin byte shim, keep it alive with a foreground service, and restore the Android file flows (SAF content-URI caching, share intents, `privet://` deeplink, opening received files).

**Architecture:** The Android IPC transport is a Kotlin `MethodChannel`/`EventChannel` pair (`privet/ipc`) doing dumb byte I/O on a `LocalSocket`; Dart assembles frames with the same `PrivetIpcClient` from Plan 2. The daemon binary ships per-ABI in `assets/bin/<abi>/privetd`, is extracted to `<files>/privet/bin/`, and spawned by the supervisor with `--config <files>/privet/config.json --ipc <files>/privet/privet.sock`. A foreground service pins the process so the daemon survives activity backgrounding. SAF pickers cache `content://` URIs to real paths before `send`; `SEND` intents and `privet://` deeplinks reuse the pending-share and pairing flows from Plans 3.

**Tech Stack:** Kotlin, Android NDK + `cargo-ndk` (daemon cross-compile), Flutter Android embedder, `path_provider`, `open_file` + `FileProvider`.

**Target repo:** `D:\C-Codes\privet-app`. The daemon to cross-compile: `D:\C-Codes\privet`.

## Global Constraints

- Android is the primary dev target (per the design decisions): the app must run on a physical Android device / emulator before Windows polish.
- The daemon stays the sole engine owner; on Android it is a separate OS process in the same app sandbox (same uid). IPC is a unix socket under the app's private files dir, **not** TCP.
- All protocol/framing stays in Dart; the Kotlin shim is byte-only and logs to logcat (`Log.d`) so `flutter run` shows one console.
- SAF `content://` URIs must be cached to app-private real paths before any `send` — the daemon only reads real paths.
- The on-device daemon cross-compile is the flagged high-risk item (design §12); Task 1 spikes it first.
- Android save dir = app **external** files dir `/Privet` so received files are user-visible.
- Verification per task: `flutter analyze` clean, `flutter test` green, and on-device `flutter run` checks where integration is required.

---
---

### Task 1: Spike — cross-compile `privetd` for Android

**Files:**
- Create: `tool/build_privetd.sh`
- Create: `tool/README.md` (build + bundling notes)

**Interfaces:**
- Consumes: the privet workspace (`D:\C-Codes\privet`).
- Produces: `assets/bin/arm64-v8a/privetd`, `assets/bin/armeabi-v7a/privetd`, `assets/bin/x86_64/privetd`.

- [ ] **Step 1: Verify the toolchain**

Install/verify: Android NDK (via Android Studio SDK manager), Rust, and `cargo-ndk`:

```bash
rustup target list --installed   # need aarch64-linux-android, armv7-linux-androideabi, x86_64-linux-android
cargo install cargo-ndk
```

- [ ] **Step 2: Write the build script**

Create `tool/build_privetd.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
# Cross-compiles privetd for Android ABIs and stages binaries under assets/bin.
PRIVET_REPO="${PRIVET_REPO:-/workspace/privet}"   # or D:/C-Codes/privet
OUT="$(cd "$(dirname "$0")/.." && pwd)/assets/bin"
rm -rf "$OUT"
mkdir -p "$OUT/arm64-v8a" "$OUT/armeabi-v7a" "$OUT/x86_64"

cd "$PRIVET_REPO"
for spec in "aarch64-linux-android:arm64-v8a" "armv7-linux-androideabi:armeabi-v7a" "x86_64-linux-android:x86_64"; do
  target="${spec%%:*}"; abi="${spec##*:}"
  cargo ndk -t "$abi" -o "$OUT/$abi" build -p privet-daemon --bin privetd --release
done
# cargo-ndk renames the binary to libprivetd.so; keep the ELF runnable by exec:
for abi in arm64-v8a armeabi-v7a x86_64; do
  mv "$OUT/$abi/lib/arm64-v8a/privetd" "$OUT/$abi/privetd" 2>/dev/null || \
  mv "$OUT/$abi/privetd" "$OUT/$abi/privetd" 2>/dev/null || true
done
```

> **Risk gate:** this is the flagged spike. If any crate fails to cross-compile (`rusqlite` bundled, `quinn`, `mdns-sd`, `default-net`, `socket2`), stop and record the exact error — the design lists this as the first thing to validate. `cargo-ndk` typically emits binaries under `target/<triple>/release/privetd`; adapt the copy step to the actual layout. The key requirement is an **executable ELF** (the daemon is `exec`'d, not `dlopen`'d), so confirm `file privetd` reports an Android ELF and the binary is `chmod +x` in the bundle.

- [ ] **Step 3: Add the binaries to the app**

Commit the staged `privetd` ELFs under `assets/bin/<abi>/` (they are small; a release `privetd` with `--no-default-features` trimming is optional later).

- [ ] **Step 4: Verify**

Run: `bash tool/build_privetd.sh` and confirm the three ELFs exist and are executable.

- [ ] **Step 5: Commit**

```bash
git add tool/build_privetd.sh tool/README.md assets/bin
git commit -m "feat(android): cross-compile and bundle privetd per ABI"
```

---
---

### Task 2: Kotlin IPC shim (`privet/ipc` channel)

**Files:**
- Create: `android/app/src/main/kotlin/app/privet/privet_app/PrivetIpcChannel.kt`
- Modify: `android/app/src/main/kotlin/app/privet/privet_app/MainActivity.kt`
- Create: `lib/services/ipc/android_channel_transport.dart`
- Test: `test/ipc/android_channel_transport_test.dart` (Dart side, mocked channel)

**Interfaces:**
- Consumes: `Transport`, `TransportConnection` (Plan 2).
- Produces:

```kotlin
// MethodChannel 'privet/ipc': open(path), write(bytes), close()
// EventChannel 'privet/ipc/events': byte chunks (Uint8List)
```

```dart
class AndroidChannelTransport implements Transport {
  AndroidChannelTransport(this.socketPath);
  final String socketPath;
  Future<TransportConnection> connect();
}
```

- [ ] **Step 1: Register the channel in `MainActivity`**

Modify `MainActivity.kt`:

```kotlin
package app.privet.privet_app

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PrivetIpcChannel(this).register(
            MethodChannel(flutterEngine?.dartExecutor?.binaryMessenger, "privet/ipc"),
            io.flutter.plugin.common.EventChannel(flutterEngine?.dartExecutor?.binaryMessenger, "privet/ipc/events"),
        )
    }
}
```

- [ ] **Step 2: Implement `PrivetIpcChannel.kt`**

```kotlin
package app.privet.privet_app

import android.content.Context
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dumb byte bridge to the on-device privetd unix socket. No protocol logic. */
class PrivetIpcChannel(private val context: Context) {
    private var socket: LocalSocket? = null
    private var readerThread: Thread? = null
    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    fun register(channel: MethodChannel, eventChannel: EventChannel) {
        channel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "open" -> open(call.argument<String>("path"), result)
                "write" -> write(call.argument<ByteArray>("data"), result)
                "close" -> { close(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                this@PrivetIpcChannel.events = events
            }
            override fun onCancel(arguments: Any?) { events = null }
        })
    }

    private fun open(path: String?, result: MethodChannel.Result) {
        if (path == null) { result.error("invalid_request", "path required", null); return }
        try {
            val s = LocalSocket()
            s.connect(LocalSocketAddress(path, LocalSocketAddress.Namespace.FILESYSTEM))
            socket = s
            readerThread = Thread { readLoop(s) }.apply { isDaemon = true; start() }
            Log.d("PrivetIpc", "opened socket $path")
            result.success(null)
        } catch (e: Exception) {
            Log.e("PrivetIpc", "open failed", e)
            result.error("io", e.message, null)
        }
    }

    private fun write(data: ByteArray?, result: MethodChannel.Result) {
        try {
            val s = socket ?: throw IllegalStateException("socket not open")
            s.outputStream.write(data ?: ByteArray(0))
            s.outputStream.flush()
            result.success(null)
        } catch (e: Exception) {
            result.error("io", e.message, null)
        }
    }

    private fun readLoop(s: LocalSocket) {
        val buf = ByteArray(64 * 1024)
        try {
            while (true) {
                val n = s.inputStream.read(buf)
                if (n <= 0) break
                val chunk = buf.copyOf(n)
                main.post { events?.success(chunk) }
            }
        } catch (e: Exception) {
            Log.e("PrivetIpc", "read loop ended", e)
        } finally {
            main.post { events?.endOfStream() }
        }
    }

    private fun close() {
        readerThread?.interrupt()
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        readerThread = null
    }
}
```

- [ ] **Step 3: Implement `android_channel_transport.dart`**

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'transport.dart';

class AndroidChannelTransport implements Transport {
  AndroidChannelTransport(this.socketPath);
  final String socketPath;

  static const MethodChannel _method = MethodChannel('privet/ipc');
  static const EventChannel _events = EventChannel('privet/ipc/events');

  @override
  Future<TransportConnection> connect() async {
    await _method.invokeMethod<void>('open', {'path': socketPath});
    final incoming = StreamController<List<int>>();
    final out = StreamController<List<int>>();

    _events.receiveBroadcastStream().listen(
          (chunk) => incoming.add((chunk as Uint8List)),
          onError: (Object e) => incoming.addError(e),
          onDone: () async {
            await incoming.close();
            await out.close();
          },
        );

    out.stream.listen((bytes) {
      _method.invokeMethod<void>('write', {'data': bytes});
    }, onError: (_) {}, onDone: () => _method.invokeMethod<void>('close'));

    return TransportConnection(incoming: incoming.stream, out: out.sink);
  }
}
```

- [ ] **Step 4: Dart-side test (mocked channel)**

`test/ipc/android_channel_transport_test.dart` uses `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler`/`setMockStreamHandler` to assert `open` is called with the socket path and outbound writes reach `write`. This verifies the Dart side without a device; the real byte exchange is Task 9's on-device smoke.

- [ ] **Step 5: Verify**

Run: `flutter analyze && flutter test`
Expected: clean; channel test passes.

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/kotlin/app/privet/privet_app/PrivetIpcChannel.kt android/app/src/main/kotlin/app/privet/privet_app/MainActivity.kt lib/services/ipc/android_channel_transport.dart test/ipc/android_channel_transport_test.dart
git commit -m "feat(android): privet/ipc unix-socket channel shim"
```

---
---

### Task 3: On-device daemon — extract, spawn, endpoint

**Files:**
- Modify: `lib/services/daemon_supervisor.dart` (Android branch)
- Create: `lib/services/android/daemon_bundle.dart`
- Create: `lib/services/android/daemon_config.dart`
- Test: `test/services/android/daemon_bundle_test.dart`

**Interfaces:**
- Consumes: `path_provider`, `rootBundle`.
- Produces:

```dart
class AndroidDaemonBundle {
  Future<String> extract();      // returns the executable path
  Future<String> writeConfig();  // writes config.json; returns its path
  String get socketPath;         // <files>/privet/privet.sock
  String get saveDir;            // <externalFiles>/Privet
}

Transport androidTransportFactory(String socketPath); // AndroidChannelTransport
```

- [ ] **Step 1: Write the failing test**

`test/services/android/daemon_bundle_test.dart` — with a temp dir standing in for the app files dir, `extract()` copies a staged `assets/bin/<abi>/privetd` and marks it executable; `writeConfig()` produces strict JSON:

```dart
test('extract copies the bundled binary and marks it executable', () async {
  final bundle = AndroidDaemonBundle(appFilesDir: tmp, abi: 'arm64-v8a', assetRoot: 'assets/bin');
  final bin = await bundle.extract();
  expect(File(bin).existsSync(), isTrue);
  expect(File(bin).statSync().mode & 0x111, isNot(0)); // has an exec bit
});

test('writeConfig emits valid daemon config', () async {
  final cfgPath = await bundle.writeConfig();
  final cfg = jsonDecode(await File(cfgPath).readAsString());
  expect(cfg['save_dir'], endsWith('Privet'));
});
```

> Extract the ABI via `defaultTargetPlatform` + `Architecture` (or a `Platform`-free helper) so the test can inject it. `assets/bin/<abi>/privetd` must be marked as an asset in `pubspec.yaml`.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/android/daemon_bundle_test.dart`
Expected: FAIL — files don't exist.

- [ ] **Step 3: Implement `daemon_bundle.dart`**

```dart
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

String androidAbi() {
  // arm64-v8a / armeabi-v7a / x86_64 — resolved via dart:io 'ABI' when available,
  // else mapped from `Platform.version`. Tests inject it instead.
  throw UnsupportedError('resolve ABI at runtime');
}

class AndroidDaemonBundle {
  AndroidDaemonBundle({String? appFilesDir, this.abi = 'arm64-v8a', this.assetRoot = 'assets/bin'})
      : appFilesDir = appFilesDir ?? ''; // set in extract() via getApplicationSupportDirectory

  final String? appFilesDir;
  final String abi;
  final String assetRoot;

  String get _privetDir => '${appFilesDir}/privet';
  String get socketPath => '$_privetDir/privet.sock';
  String get saveDir => throw UnsupportedError('set from external files dir');

  Future<String> extract() async {
    final dir = Directory('$_privetDir/bin');
    await dir.create(recursive: true);
    final target = File('${dir.path}/privetd');
    if (!target.existsSync()) {
      final data = await rootBundle.load('$assetRoot/$abi/privetd');
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    await Process.run('chmod', ['700', target.path]); // or File.setExecutable
    return target.path;
  }

  Future<String> writeConfig() async {
    final dir = Directory('$_privetDir');
    await dir.create(recursive: true);
    final file = File('${dir.path}/config.json');
    await file.writeAsString(jsonEncode({
      'device_name': 'privet-device',
      'data_dir': '$_privetDir/data',
      'save_dir': saveDir,
      'ipc_endpoint': socketPath,
      'quic_port': 0, 'tcp_port': 0, 'discovery_port': 0,
    }));
    return file.path;
  }
}
```

> `saveDir` = `<externalFiles>/Privet`; resolve with `getExternalStorageDirectory()` (app-owned external files, no permission needed) and pass it into the bundle. `pubspec.yaml` must declare the binaries as assets (they are not auto-included):

```yaml
flutter:
  assets:
    - assets/bin/arm64-v8a/privetd
    - assets/bin/armeabi-v7a/privetd
    - assets/bin/x86_64/privetd
```

- [ ] **Step 4: Wire the supervisor's Android branch**

In `daemon_supervisor.dart`, add an Android-aware factory (used by `DaemonStateNotifier.start` on Android):

```dart
Future<DaemonSupervisor> androidSupervisor(WidgetRef ref) async {
  final bundle = AndroidDaemonBundle(abi: androidAbi());
  final appFiles = (await getApplicationSupportDirectory()).path;
  final external = (await getExternalStorageDirectory())?.path ?? appFiles;
  // construct bundle with the real dirs, extract + writeConfig
  final executable = await bundle.extract();
  final config = await bundle.writeConfig();
  return DaemonSupervisor(
    endpoint: bundle.socketPath,
    executablePath: executable,
    configPath: config,
    transportFactory: () => AndroidChannelTransport(bundle.socketPath),
  );
}
```

- [ ] **Step 5: Verify**

Run: `flutter analyze && flutter test test/services/android/daemon_bundle_test.dart`
Expected: clean; bundle tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/services/android/daemon_bundle.dart lib/services/android/daemon_config.dart lib/services/daemon_supervisor.dart test/services/android/daemon_bundle_test.dart pubspec.yaml
git commit -m "feat(android): on-device daemon extraction, config and spawn wiring"
```

---
---

### Task 4: Foreground service

**Files:**
- Create: `android/app/src/main/kotlin/app/privet/privet_app/PrivetDaemonService.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Create: `android/app/src/main/res/values/strings.xml` (notification strings)

**Interfaces:**
- Consumes: nothing.
- Produces: a START_STICKY foreground service that pins the process while the daemon runs.

- [ ] **Step 1: Implement `PrivetDaemonService.kt`**

```kotlin
package app.privet.privet_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder

/** Keeps the app process alive so the on-device privetd child survives UI kills. */
class PrivetDaemonService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel("privet-daemon", "Privet daemon", NotificationManager.IMPORTANCE_LOW)
        nm.createNotificationChannel(channel)
        val notification = Notification.Builder(this, "privet-daemon")
            .setContentTitle("Privet")
            .setContentText("Transfer daemon running")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .build()
        startForeground(1, notification)
        return START_STICKY
    }
}
```

- [ ] **Step 2: Declare it in `AndroidManifest.xml`**

Add under `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>
```

Add under `<application>`:

```xml
<service
    android:name=".PrivetDaemonService"
    android:foregroundServiceType="dataSync"
    android:exported="false"/>
```

- [ ] **Step 3: Start the service from Dart**

In `AndroidDaemonBundle` (or a small helper), add:

```dart
Future<void> startForegroundService() async {
  const channel = MethodChannel('privet/daemon_service');
  await channel.invokeMethod('start');
}
```

And in Kotlin, register a `start` handler in `MainActivity` (or reuse `PrivetIpcChannel`):

```kotlin
MethodChannel(binaryMessenger, "privet/daemon_service").setMethodCallHandler { call, result ->
    if (call.method == "start") {
        val intent = Intent(this, PrivetDaemonService::class.java)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        result.success(null)
    } else result.notImplemented()
}
```

> `foregroundServiceType="dataSync"` + `FOREGROUND_SERVICE_DATA_SYNC` permission is required on Android 14+ for a data-transfer service. Call `startForegroundService()` after `extract()`/`writeConfig()` and after the daemon is confirmed running.

- [ ] **Step 4: Verify on device**

Run: `flutter run` on an emulator; confirm the notification appears and the process survives a few seconds of backgrounding.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/kotlin/app/privet/privet_app/PrivetDaemonService.kt android/app/src/main/AndroidManifest.xml android/app/src/main/res/values/strings.xml
git commit -m "feat(android): foreground service keeps daemon alive"
```

---
---

### Task 5: SAF content-URI caching

**Files:**
- Create: `lib/services/android/content_uri_helper.dart`
- Create: `lib/services/android/content_uri_dir_helper.dart`
- Port from: `D:\C-Codes\privet-old\privet_app\lib\services\privet\content_uri_helper.dart`, `content_uri_dir_helper.dart`

**Interfaces:**
- Consumes: Android platform channels for content URIs.
- Produces:

```dart
class ContentUriHelper {
  Future<String?> cacheToPath(String contentUri);   // copies to <cache>/privet/send-cache/<session>/
  Future<String?> openContentUri(String contentUri);
}
class ContentUriDirectoryHelper {
  Future<List<CachedFileEntry>?> pickAndCacheDirectory(); // SAF tree → cached real paths
}
```

**Porting spec (read the old files first):**
- Port the MethodChannel wrappers (`privet/file` channel) and the native handlers into this app's Android project (the old app's `ContentUriHelper` Kotlin/Java side must be re-added in `MainActivity` or a new file).
- The caching target is now `<cache>/privet/send-cache/<session>/` (app cache dir via `path_provider` `getTemporaryDirectory`). Keep the relative-path preservation so the send file tree renders correctly.
- Clean up `send-cache/<session>` after the transfer completes (hook into `transfer_completed`/`failed`/`cancelled` in the send flow).

- [ ] **Step 1: Port the Dart wrappers**

Copy both old files, adapt the cache root to `getTemporaryDirectory()/privet/send-cache`.

- [ ] **Step 2: Port the native handlers**

Copy the old app's `privet/file` MethodChannel handlers (Kotlin) into `MainActivity.kt`, exposing `copyContentUri`, `openContentUri`, `checkContentUri`, and `pickDirectory` (SAF `ACTION_OPEN_DOCUMENT_TREE` → per-file `absolutePath|relativePath` strings). This is ~150 lines of Kotlin ported verbatim.

- [ ] **Step 3: Wire into send preparation**

In `send_preparation_page.dart`, the Android "Add files/folder" actions use the SAF pickers and push cached paths into `sendPreparationProvider.addFiles` (the old `_pickFiles`/`_pickFolder` already did this — port the Android branches).

- [ ] **Step 4: Verify**

Run: `flutter analyze`
Expected: clean. On-device picker flow verified in Task 9.

- [ ] **Step 5: Commit**

```bash
git add lib/services/android/content_uri_helper.dart lib/services/android/content_uri_dir_helper.dart
git commit -m "feat(android): SAF content-URI caching for send paths"
```

---
---

### Task 6: Share intents

**Files:**
- Modify: `android/app/src/main/kotlin/app/privet/privet_app/MainActivity.kt`
- Modify: `lib/main.dart` (pending-share plumbing)
- Port from: old `lib/main.dart` share-intent logic.

**Porting spec (read the old `main.dart` first):**
- Add `ACTION_SEND` handling: `MainActivity.onCreate` processes the intent, collects `ClipData` content URIs, and forwards them to Flutter over the `privet/share` MethodChannel (`onShare` push + `getPendingShare` pull), exactly like the old app.
- In Dart, port the `pendingShareProvider` + the ShellPage listener that pushes `SendPreparationPage` — but feed the cached paths through `ContentUriHelper.cacheToPath` before `addFiles`.
- The old `_pullPendingShare` on app-resume logic is ported unchanged.

- [ ] **Step 1: Port the intent handling (Kotlin)**

Copy the old `onShare`/`getPendingShare` channel logic into `MainActivity.kt`, updated to use this app's package.

- [ ] **Step 2: Port the Dart side**

Port `pendingShareProvider` and the ShellPage listener from the old app, adding the content-URI cache step.

- [ ] **Step 3: Verify**

Run: `flutter analyze`
Expected: clean. On-device share test in Task 9.

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/kotlin/app/privet/privet_app/MainActivity.kt lib/main.dart
git commit -m "feat(android): share-intent plumbing into send preparation"
```

---
---

### Task 7: `privet://` deeplink intent-filter

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`

**Interfaces:**
- Consumes: `app_links` (Plan 3) + `PairingUrl.parse`.

- [ ] **Step 1: Add the intent filter**

Under the `MainActivity` `<activity>`:

```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <category android:name="android.intent.category.BROWSABLE"/>
    <data android:scheme="privet"/>
</intent-filter>
```

- [ ] **Step 2: Verify**

Run: `adb shell am start -a android.intent.action.VIEW -d "privet://pair?h=10.0.0.5:47808&fp=abc&n=phone&code=123456" app.privet.privet_app`
Expected: the app opens; the pairing flow (Plan 3 Task 10) receives the URL.

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/AndroidManifest.xml
git commit -m "feat(android): privet:// deeplink intent filter"
```

---
---

### Task 8: FileProvider for opening received files

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Create: `android/app/src/main/res/xml/file_paths.xml`

**Interfaces:**
- Consumes: `open_file` package.

- [ ] **Step 1: Add the provider**

Under `<application>`:

```xml
<provider
    android:name="androidx.core.content.FileProvider"
    android:authorities="${applicationId}.fileprovider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/file_paths"/>
</provider>
```

Create `android/app/src/main/res/xml/file_paths.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <external-files-path name="privet_received" path="Privet/"/>
    <files-path name="privet_internal" path="privet/"/>
    <cache-path name="privet_cache" path="privet/"/>
</paths>
```

- [ ] **Step 2: Verify**

On device, open a received file from History → it launches with the system viewer.

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/AndroidManifest.xml android/app/src/main/res/xml/file_paths.xml
git commit -m "feat(android): FileProvider for opening received files"
```

---
---

### Task 9: On-device end-to-end smoke

**Files:**
- Create: `test_driver/` integration harness (optional) or manual checklist.

- [ ] **Step 1: Two-device (or emulator-host) smoke**

Run `flutter run` on two Android emulators/devices (or one Android + the Windows app from Plan 3) and verify:
1. Home shows the identity card + nearby devices (mDNS/UDP discovery).
2. QR pairing: device A shows QR with code; device B scans/pastes → paired → trusted list updates.
3. Send a folder from device A → B shows the awaiting-accept tile → Accept → files land in the external files `/Privet`.
4. History on B shows the receive; expanding shows the file tree; Open file launches the viewer; Delete removes it.
5. Background B's app (Home) — the daemon keeps running (foreground service) and a transfer still completes.
6. Share a file to the app from another app (files → Share → Privet) → SendPreparationPage opens with the file cached.

- [ ] **Step 2: Fix + commit**

Any failures get fixed in the owning task's file and committed with a descriptive message. Record the checklist results in the plan's execution notes.

---
---

## Self-review notes

- **Spec coverage vs design §5:** transport shim (T2), on-device daemon + extraction/spawn (T3), foreground service (T4), SAF caching (T5), share intents (T6), deeplink (T7), FileProvider (T8), cross-compile spike (T1), smoke (T9). The `privet_android_ipc` plugin is realized as a MainActivity channel rather than a standalone plugin package — simpler for a single app; note this deviation.
- **Known risks carried from the design:** (1) the Android cross-compile (T1) is the first task for a reason; (2) `dart:io` `Process.start` of an extracted ELF must be verified on-device in T3; (3) the `abi` resolver needs a real implementation (`androidAbi()`) — the plan stubs it and tests inject it.
- **Type consistency:** `AndroidChannelTransport` implements `Transport` from Plan 2; `DaemonSupervisor` Android branch uses the same `endpoint`/`executablePath`/`configPath` fields; `androidSupervisor(...)` returns the same `DaemonSupervisor` type the rest of the app consumes.
