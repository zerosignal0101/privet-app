# Privet App — Daemon + IPC Design

Date: 2026-08-26
Status: Approved design (brainstorming output)
Scope: Reimagination of the `privet-app` GUI as a thin client of the `privetd` daemon over local IPC, combining the old Flutter GUI's interactions, page layout, and dependency choices with the newly implemented Rust daemon's contract.

## 1. Context and goals

`privetd` (repo `D:\C-Codes\privet`) is a daemon-first LAN file-transfer engine. It is the sole owner of the engine, private keys, network sockets, SQLite database, receive staging tree, pairing codes, trust decisions, and active transfers. Clients must not embed the core, open the database, or bind sockets; they communicate over a local IPC contract (spec 09 of the daemon repo).

The old GUI (`D:\C-Codes\privet-old\privet_app`) was a Flutter app that embedded the Rust core via FFI (`privet_ffi` + isolate). That architecture is obsolete: the new app is a **pure IPC client**. The goal is to preserve the old app's proven UX (3-tab shell, sectioned Home feed, send-preparation compose flow, history records, pairing banners/dialog/QR, settings) while reimplementing its data layer against the daemon's request/response + event contract.

### 1.1 Decisions made in brainstorming

| # | Decision | Choice |
|---|---|---|
| D1 | GUI stack | Flutter (single app), desktop + Android |
| D2 | Platform priority | Android is the primary dev/debug target; Windows is the second; Linux/macOS should-work |
| D3 | Daemon lifecycle | Hybrid: connect-if-running, else spawn as child; app owns config file and restart |
| D4 | Feature scope | Parity where the daemon supports it + reimagined gaps within the existing IPC contract |
| D5 | Android engine model | On-device daemon: cross-compiled `privetd` bundled, extracted, spawned in the app sandbox |
| D6 | IPC client | Pure-Dart protocol client; transport via `win32` (Windows), Kotlin platform channel (Android), `dart:io` unix socket (Linux/macOS) |
| D7 | History | Extend the daemon's IPC with `get_history_detail` and `delete_history` (file data already persisted) |

## 2. Architecture

```
┌───────────────────────────────────────────────────────────────┐
│ Flutter UI  (ported from old app)                              │
│   ShellPage (Home / History / Settings) · SendPreparationPage  │
│   pairing banners/dialog/QR · transfer tiles · file tree        │
│   Riverpod state layer                                         │
├───────────────────────────────────────────────────────────────┤
│ Dart IPC client  (new, 100% Dart)                              │
│   services/ipc/                                                │
│     protocol.dart     — framing (4-byte BE len + JSON),        │
│                         envelope, DTOs, event types            │
│     client.dart       — request/response correlation,          │
│                         event stream, replay, session-UUID     │
│                         reconciliation, timeout                │
│     transport.dart    — abstract Transport (connect/read/      │
│                         write/close)                           │
│       named_pipe_transport.dart     — Windows, via win32       │
│       unix_socket_transport.dart    — Linux/macOS, dart:io     │
│       android_channel_transport.dart — Android, Kotlin channel │
│   services/privet_service.dart  — facade, maps 1:1 to IPC      │
├───────────────────────────────────────────────────────────────┤
│ Daemon supervisor  (new, Dart)                                 │
│   locate → spawn-or-attach privetd → manage config file →      │
│   restart-on-config-change → monitor exit → shutdown on quit   │
└───────────────────────────────────────────────────────────────┘
                               │  IPC
                               ▼
        ┌──────────────────────────────────────────────┐
        │ privetd (Rust daemon, built from privet repo)│
        │  Windows: named pipe \\.\pipe\privet-user-v1 │
        │  Android: unix socket in app data            │
        │  Linux/macOS: unix socket in runtime dir     │
        └──────────────────────────────────────────────┘
```

Component responsibilities:
- **UI** — rendering only; no protocol knowledge. Riverpod providers mirror daemon snapshots and event-derived state.
- **IPC client** — the entire daemon contract in Dart. Replaces the old `PrivetService` FFI calls with IPC requests; the event stream replaces the old FFI callback poll.
- **Daemon supervisor** — owns process lifecycle and the app-managed config file. Single owner of connect/spawn/restart/reconnect.
- **Transport** — three backends behind one abstract interface; each is dumb byte I/O only, no protocol logic.

### 2.1 Platform / transport / daemon matrix

| Platform | Transport | Daemon endpoint | privetd source |
|---|---|---|---|
| Windows | `win32` named pipe | `\\.\pipe\privet-user-v1` | bundled exe (built from privet repo) |
| Android | Kotlin channel → unix socket | `--ipc <app data>/privet/privet.sock` | bundled ELF per ABI, extracted + exec'd |
| Linux/macOS | `dart:io` unix socket | default runtime-dir socket | bundled or system binary |

## 3. The Dart IPC client (`services/ipc/`)

Pure-Dart package with no platform deps except the transport backends.

### 3.1 `protocol.dart`

- Constants: `IPC_PROTOCOL_VERSION = 1`, `MAX_IPC_MESSAGE_BYTES = 1 MiB`.
- Framing: read/write `u32 BE length + UTF-8 JSON`. Zero-length, oversized, truncated, or invalid JSON frames terminate the connection (mirroring daemon behavior).
- Envelope: `{protocol_version, request_id, request{method, params}}`; unknown fields rejected.
- Server messages: response `{request_id, payload|error}` (exactly-one invariant) or event `{sequence, event}`.
- DTOs mirroring `privet-ipc`'s `protocol.rs`: `DaemonStatus`, `IdentityDto`, `PeerDto` + `CandidateAddressDto`, `TrustedPeerDto`, `TransferSummaryDto`, `HistoryEntryDto`, `RuntimeConfigDto`, plus the new `HistoryDetailDto` (see §7).
- Events: a sealed `PrivetEvent` with the 17 variants (device_discovered, device_lost, pairing_requested, pairing_result, transfer_preparing, transfer_preparing_progress, transfer_offered, transfer_progress, transfer_reconnecting, transfer_resumed, transfer_paused, transfer_completed, transfer_cancelled, transfer_failed, incoming_connection, runtime_config_changed, daemon_stopping).
- Errors: `PrivetIpcException(code, message)`; Dart branches on the stable `code` only, never message text.

### 3.2 `client.dart`

- `PrivetIpcClient(Transport)`: one reader task, request correlation.
- `call(Request, {timeout: 30s})` writes the envelope and awaits a `Completer` keyed by `request_id`; responses may arrive out of order.
- Events flow to a broadcast `Stream<EventMessage>`; a reader loop dispatches response-vs-event and detects transport close (`daemon disconnected`).
- **No auto-reconnect inside the client** — mirrors the Rust `IpcClient`; reconnect is owned by the supervisor so one place owns process + connection state.

### 3.3 `transport.dart`

Abstract `Transport` → `TransportConnection { bytes stream; write(); close(); }`. Backends:

- **Windows** `NamedPipeTransport` — `win32` package: `CreateFileW` on `\\.\pipe\privet-user-v1`, async `ReadFile`/`WriteFile`, busy-retry (Windows error 231) at 50 ms.
- **Linux/macOS** `UnixSocketTransport` — `dart:io` `UnixDomainSocket.connect`.
- **Android** `AndroidChannelTransport` — Kotlin platform channel doing open/read/write/close on the unix socket; Dart assembles frames.

### 3.4 `privet_service.dart` — facade

Keeps the old app's API shape so providers port cleanly, now mapping 1:1 to IPC requests:
- Queries: status, identity, peers, trusted, history (+ detail), runtime config.
- Actions: pair, revoke/forget, send, accept/reject, pause/cancel/continue, resume/resend, delete history, set runtime config.
- Lifecycle: `connect()` performs the spec-09 §12 sequence — `ping` → `subscribe_events` → replay → snapshot → dedupe by `(session_id, sequence)`; on session change or gap, refresh status/peers/trust/history/config. Persists the event cursor locally so a restart resumes cleanly.

## 4. Daemon lifecycle & config management (`daemon_supervisor.dart`)

- States: `stopped → starting → running → stopping` (+ `error`).
- `ensureRunning()` — try a live connect first (attach if a daemon answers `ping`); if absent, spawn:
  - **Windows:** locate bundled `privetd.exe`, spawn `privetd --config <app-config>`.
  - **Android:** extract `assets/bin/<abi>/privetd`, chmod +x, `Process.start` with `--config <app-config> --ipc <app-data>/privet/privet.sock`.
  - Poll connect until alive (bounded ~10 s), then run the §3.4 connect dance.
- **Monitor:** child exit → if unintentional, surface "daemon crashed" and offer restart. A foreground service keeps the daemon alive across app backgrounding on Android.
- `shutdown()`: send `shutdown` IPC, await the flush-ack, wait for process exit. "Leave daemon running after app quit" is a Settings toggle.

### 4.1 Config file

The app owns `<app-data>/privet/config.json` (the daemon's strict-JSON schema, unknown fields rejected):
- **Live via `set_runtime_config`** (no restart): `save_dir`, `accept_all_trusted`, `collision_policy`.
- **Restart-required** (edit file → `shutdown` → respawn → reconnect): `device_name`, `quic_port`, `tcp_port`, `discovery_port`, pairing policy.

### 4.2 Directories

| Platform | data_dir | save_dir (received files) |
|---|---|---|
| Windows | `%LOCALAPPDATA%\privet` (daemon default) | Downloads/privet or user-chosen |
| Android | app files dir | app **external** files `/Privet` (user-accessible on-device) |
| Linux/macOS | XDG data dir | XDG Downloads |

## 5. Android integration

### 5.1 Transport shim

Small first-party Flutter plugin `privet_android_ipc` (Kotlin only — Windows uses the win32 Dart package, so no C++ plugin). MethodChannel `privet/ipc` + EventChannel for inbound bytes:
- `open(path)` → `LocalSocket` (AF_UNIX) connected to the daemon socket; `write(bytes)`, `close()`; inbound bytes streamed to Dart.
- Dumb byte I/O only — all framing in Dart. The shim's `Log.d` output appears in `flutter run`'s logcat, keeping logs in one console.

### 5.2 On-device daemon

- Bundle `privetd` per ABI in `assets/bin/<abi>/` (arm64-v8a, armeabi-v7a, x86_64). A build script cross-compiles via `cargo-ndk` against the privet repo (couples the app build to the daemon repo — an accepted cost).
- First run: extract to `<files>/privet/bin/privetd`, make executable, `Process.start(['--config', cfg, '--ipc', <files>/privet/privet.sock])`.
- **Foreground service** (`PrivetDaemonService`) keeps the daemon alive when the Flutter activity is backgrounded — transfers survive UI restarts. This is the payoff of daemon-first on Android.

### 5.3 Files on Android

- **SAF pickers return `content://` URIs; the daemon needs real paths** → port the old caching pattern: copy picked content into `<cache>/privet/send-cache/<session>/` (files and directory trees via the ported `ContentUriDirectoryHelper.pickAndCacheDirectory`), send real paths, clean up after the transfer. This is the one piece of old Android machinery that must return.
- **Share intents** (`SEND`) → port the old pending-share plumbing → SendPreparationPage.
- **Deeplink** `privet://` via `app_links` (Android intent-filter + Windows protocol registration). Port `deeplink_service.dart` + `pairing_url.dart`, extended to carry the pairing code.
- **Received files** land in app external files `/Privet`; "Open file" uses a `FileProvider` + the `open_file` package.

## 6. Feature & UX reimagination

### 6.1 Ported pages (layout/UX preserved, data source swapped)

| Page | Old engine source | New daemon source |
|---|---|---|
| Home — nearby/known devices | FFI peer events | `list_peers` + `device_discovered/lost` |
| Home — active transfers | FFI progress events | `transfer_*` events + `get_status.active_transfers` |
| Home — pairing banners | FFI pair events | `pairing_requested` events |
| Send — recipient picker | peer addresses | **fingerprint** (`send` takes trusted fp) |
| History | FFI history with file lists | `list_history` + `get_history_detail` |
| Settings | FFI + prefs | `get/set_runtime_config` + config file |

### 6.2 Reimagined gaps (within the IPC contract)

1. **QR pairing** — the old QR encoded `{hosts, fingerprint, name}`. New: device A `generate_pairing_code` → QR encodes `{hosts, fingerprint, code, name}`; device B scans (camera on Android / paste-URL on desktop) → verifies fingerprint → `pair(endpoint-from-QR, code)`. Both sides share the SPAKE2 code, so it is within the contract.
2. **Send-by-address** — the daemon removed raw-address sending. Reimagined as **pair-by-address**: enter IP:port, ask the target to display its code, `pair(endpoint, code)`, then send.
3. **Inline pairing card on Send** — when the target is not trusted, the send page shows a two-sided pairing card (display-my-code / enter-their-code), driven by `generate_pairing_code` + `pairing_requested` + `pair`, then proceeds.
4. **Settings that moved into the daemon** — `device_name` + ports are restart-required: the app edits `config.json` → `shutdown` → respawn (supervisor-owned). `save_dir`, `accept_all_trusted`, `collision_policy` are live via `set_runtime_config`.

### 6.3 Dropped features (no daemon equivalent)

- Per-device auto-accept list (daemon has only global `accept_all_trusted`); the star button on transfer tiles goes away.
- Known-device IP editing and network labels.
- TCP-fallback toggle (fallback is always on in the daemon).
- The 3-way "security mode" collapses to the global `accept_all_trusted` boolean.

## 7. Daemon-side IPC extensions (history detail + delete)

Required so the client can open sent/received files and forward/edit. The file data is **already persisted** (`transfer_files` populated on both send and receive completion; `save_dir` + `root_name` on receive; `send_intent` JSON on send), so the additions are cheap and low-risk.

### 7.1 `get_history_detail { transfer_id }`

Returns the transfer summary plus per-file records with a daemon-computed absolute path:
- receive: `save_dir / root_name / relative_path`
- send: `source_path` — the absolute source path **persisted per file** (schema migration v2 adds `transfer_files.source_path`). Required because `relative_path` is not globally unique across roots in a multi-root send.
- per file: `{relative_path, absolute_path, size, status}`. `is_dir` is not stored (the daemon records files only); directories are derived client-side from `relative_path` components.

### 7.2 `delete_history { transfer_id }`

Single-entry delete (new storage function; `transfer_files` cascades via FK). Storage already has clear-all and clear-by-peer.

### 7.3 Contract notes

- Keep `list_history` aggregate (light); detail is on-demand.
- Additions are additive (new methods + payload variant). Coordinated daemon + client release; the daemon repo decides whether to stay within IPC v1 (additive) or bump to v2.
- Client unlock: file lists + tree view, open-file, delete record, forward to a *different* peer (`send` with detail paths), edit-and-resend (detail paths → SendPreparationPage prefilled), resend to same peer (`resend_transfer`, already exists).

## 8. Error handling & resilience

- **Daemon absent/down** → app banner "Daemon not running" → supervisor `ensureRunning()` spawns it; UI shows `starting → running`.
- **Daemon crash** → monitor detects exit → banner "Daemon crashed" + restart offer; new `session_id` → full reconcile (refresh status/peers/trust/history/config, drop stale peers).
- **Disconnect** → client surfaces → supervisor reconnects; session change → §3.4 reconcile. The client itself never auto-reconnects (one owner).
- **IPC errors** → `PrivetIpcException(code, message)`; UI branches on code → user-facing text (`not_paired`, `transfer`, `pairing_failed`, `io`, …).
- **Async transfer failures** → events carry `error_code` + `retryable` → History status; UI offers retry/resend when retryable. Send-start returns an ID immediately.
- **Path safety** — content-URI caching copies into app-private storage before send; daemon path guards remain authoritative.

## 9. Testing

- **Dart unit** — framing (length+JSON roundtrip, oversized/truncated rejection), DTO (de)serialization against daemon fixtures, request/response correlation, replay/dedup (`session_id`, `sequence`), client state machine.
- **Transport** — client tests run against an injected in-memory `Transport`; win32 pipe covered by a Windows integration test; Android channel by an instrumented device test.
- **Widget** — pages against a mock `PrivetService` (canned responses/events), ported from the old app's approach.
- **Integration** — spawn a real `privetd`, end-to-end loopback send/receive, verify `get_history_detail` + `delete_history`.
- **Daemon repo** — new unit tests for `get_history_detail` (send + receive fixtures) and `delete_history`.

## 10. Dependencies

| Package | Role |
|---|---|
| `flutter_riverpod` | state (unchanged pattern) |
| `win32` | Windows named-pipe transport + clipboard file paths (CF_HDROP) |
| `app_links` | deeplink `privet://` (Android intent + Windows protocol) |
| `path_provider` | data directories |
| `file_picker` | file/folder/dir picking |
| `open_file` | open files |
| `qr_flutter` | QR pairing |
| `package_info_plus` | version display |
| `shared_preferences` | app settings (tab index, leave-daemon-running, etc.) |
| `image` | clipboard-image decode on Windows paste |
| `privet_android_ipc` (first-party Kotlin plugin) | Android unix-socket byte shim |

Removed vs old app: `url_launcher` (was unused), direct `ffi` usage replaced by `win32` for Windows clipboard.

## 11. Proposed app repo layout

```
privet-app/
  lib/
    main.dart
    models/          # ported models + IPC DTOs
    providers/       # Riverpod state
    pages/           # shell, home, history, send_preparation, settings
    widgets/         # file_tree_view, pairing_banner, peer_picker_sheet, transfer_tile
    services/
      ipc/           # protocol, client, transport + 3 backends
      privet_service.dart
      daemon_supervisor.dart
      deeplink_service.dart
      clipboard_service.dart
      android/       # content_uri_helper, content_uri_dir_helper (ported)
  android/           # privet_android_ipc plugin, PrivetDaemonService, FileProvider, intent filters
  windows/
  assets/bin/<abi>/privetd
  tool/build_privetd.sh   # cargo-ndk cross-compile against the privet repo
```

## 12. Risks & open items

- **Daemon cross-compile for Android** — plausible but unverified; rusqlite-bundled/quinn/mdns-sd expected to cross-compile. First implementation task should spike this.
- **Daemon-side IPC additions** — must be coordinated with the daemon repo (`get_history_detail`, `delete_history`); the app repo will be blocked on them for History parity.
- **Windows named-pipe transport via `win32`** — direct, but needs a Windows integration test early.
- **Dart `Process.start` of an extracted native binary on Android** — expected to work in the app files dir; verify in the first Android spike.
- **Send-side history detail** — resolved by persisting `transfer_files.source_path` (schema migration v2) at send completion; `relative_path` alone is ambiguous across multi-root sends. Old send records have NULL `source_path` → the client shows "File not accessible".
- IPC version policy (v1 additive vs v2) is a daemon-repo decision.
