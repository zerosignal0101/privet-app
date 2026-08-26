# Daemon IPC History Detail + Delete — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `get_history_detail` and `delete_history` to the `privetd` IPC contract so the GUI can open sent/received files and manage history, backed by a schema migration that persists per-file source paths.

**Architecture:** The file data already exists in SQLite (`transfer_files` + `transfer_history.save_dir`/`send_intent`). The only gap for send-side file reconstruction is that `relative_path` is ambiguous across multi-root sends, so a schema migration v2 adds `transfer_files.source_path` (populated at send completion from `PreparedFile.abs_path`). New IPC methods surface detail (files + daemon-computed absolute paths) and single-entry delete.

**Tech Stack:** Rust 1.81 (edition 2021), rusqlite 0.40, serde/serde_json, tokio 1, prost-free JSON IPC (privet-ipc).

**Target repo:** `D:\C-Codes\privet` (the daemon workspace). All paths below are relative to that repo.

## Global Constraints

- Workspace checks must pass after every task: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace --all-targets`.
- IPC protocol version stays **1**; the additions are additive (new method names + one new payload variant + DTOs). Do not rename/remove existing fields.
- Storage schema is versioned: `MIGRATIONS` in `privet-storage/src/migration.rs`; `schema_v1.rs` (V1_SQL) is **frozen** — never edit it; new columns go in a new `Migration { version: 2, ... }`.
- DTOs use `#[serde(deny_unknown_fields)]` and snake_case JSON names (existing conventions in `privet-ipc/src/protocol.rs`).
- IPC errors are `{ code, message }`; clients branch on `code` only. New handler errors use the existing `invalid_request` code pattern (`BackendError::invalid`).
- Any IPC or storage change MUST update the matching `SPECIFICATIONS/` document in the same change (repo rule: spec authority — see `SPEC.md` §11).
- Daemon is the sole engine owner; storage queries stay in `privet-storage`, thin engine pass-throughs in `privet-core`, IPC/DTO mapping in `privet-daemon`.

---
---

### Task 1: Storage — migration v2 adds `transfer_files.source_path`

**Files:**
- Modify: `privet-storage/src/migration.rs` (append to `MIGRATIONS`)
- Test: `privet-storage/src/migration.rs` (new `#[cfg(test)] mod tests`)

**Interfaces:**
- Consumes: existing `Migration` struct, `run_migrations`.
- Produces: `MIGRATIONS` gains `version: 2` migration named `add-transfer-files-source-path` that adds nullable column `source_path TEXT` to `transfer_files`.

- [ ] **Step 1: Write the failing migration test**

Add a `mod tests` to `privet-storage/src/migration.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_v2_adds_source_path_column_and_preserves_rows() {
        let conn = crate::db::open_in_memory().unwrap();
        // Apply only v1 (baseline) first, then seed pre-migration data.
        crate::migration::run_migrations(&conn, &[crate::migration::MIGRATIONS[0]]).unwrap();
        conn.execute_batch(
            "INSERT INTO transfer_history(transfer_id,direction,file_count,total_bytes,status,started_ts,send_intent)
             VALUES('t1','send',1,10,'completed',1,'{}');",
        )
        .unwrap();
        conn.execute_batch(
            "INSERT INTO transfer_files(transfer_id,file_id,relative_path,size,status)
             VALUES('t1','f1','a.txt',10,'completed');",
        )
        .unwrap();

        crate::migration::run_migrations(&conn, crate::migration::MIGRATIONS).unwrap();

        let source_path: Option<String> = conn
            .query_row(
                "SELECT source_path FROM transfer_files WHERE transfer_id='t1' AND file_id='f1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(source_path, None);
        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM transfer_files", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p privet-storage migration_v2_adds_source_path_column_and_preserves_rows`
Expected: FAIL with `no such column: source_path`.

- [ ] **Step 3: Add the migration**

Append to `MIGRATIONS` in `privet-storage/src/migration.rs`:

```rust
pub const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 1,
        name: "baseline",
        sql: V1_SQL,
    },
    Migration {
        version: 2,
        name: "add-transfer-files-source-path",
        sql: "ALTER TABLE transfer_files ADD COLUMN source_path TEXT;",
    },
];
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p privet-storage migration_v2`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add privet-storage/src/migration.rs
git commit -m "feat(storage): migration v2 adds transfer_files.source_path"
```

---
---

### Task 2: Storage — `FileRow.source_path` persisted by `complete_history`

**Files:**
- Modify: `privet-storage/src/history.rs` (`FileRow`, `complete_history`)
- Modify: `privet-storage/tests/path_guard_boundary.rs:60-70` (FileRow construction)
- Test: `privet-storage/src/history.rs` (mod tests)

**Interfaces:**
- Consumes: existing `FileRow<'a>` constructors.
- Produces: `FileRow<'a>` gains `pub source_path: Option<&'a str>`. `complete_history` inserts it into `source_path`.

- [ ] **Step 1: Write the failing test**

Add to `mod tests` in `privet-storage/src/history.rs`:

```rust
#[test]
fn complete_history_persists_source_path() {
    let conn = db();
    insert_history(&conn, &new_xfer("t1", None)).unwrap();
    let files = [
        FileRow {
            file_id: "f1",
            relative_path: "a.txt",
            size: 10,
            hash_type: "blake3".into(),
            hash_value: Some("dead"),
            status: "completed",
            source_path: Some("/home/u/docs/a.txt"),
        },
    ];
    complete_history(&conn, "t1", &files, 999).unwrap();
    let source_path: Option<String> = conn
        .query_row(
            "SELECT source_path FROM transfer_files WHERE transfer_id='t1' AND file_id='f1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(source_path.as_deref(), Some("/home/u/docs/a.txt"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p privet-storage complete_history_persists_source_path`
Expected: FAIL — `FileRow` has no field `source_path` (compile error).

- [ ] **Step 3: Update `FileRow` and `complete_history`**

In `privet-storage/src/history.rs`:

```rust
pub struct FileRow<'a> {
    pub file_id: &'a str,
    pub relative_path: &'a str,
    pub size: u64,
    pub hash_type: Option<&'a str>,
    pub hash_value: Option<&'a str>,
    pub status: &'a str,
    pub source_path: Option<&'a str>,
}
```

Replace the INSERT in `complete_history`:

```rust
        for f in files {
            tx.execute(
                "INSERT INTO transfer_files (transfer_id, file_id, relative_path, size, hash_type, hash_value, status, source_path)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                rusqlite::params![
                    transfer_id,
                    f.file_id,
                    f.relative_path,
                    f.size as i64,
                    f.hash_type,
                    f.hash_value,
                    f.status,
                    f.source_path,
                ],
            )?;
        }
```

- [ ] **Step 4: Fix existing `FileRow` constructors**

Add `source_path: None` to every existing `FileRow { ... }` literal (compile error will point at each). Known sites:
- `privet-storage/src/history.rs` mod tests: `complete_history_inserts_files_atomically` (2 rows), `complete_history_rolls_back_on_mid_failure` (1 row), `clear_history_wipes_both_tables` (1 row).
- `privet-storage/tests/path_guard_boundary.rs` (~line 65, inside the `complete_history` call's `files` slice).

- [ ] **Step 5: Run all storage tests to verify they pass**

Run: `cargo test -p privet-storage`
Expected: PASS (including the pre-existing migration, concurrency, orphan-reconcile, path-guard tests).

- [ ] **Step 6: Commit**

```bash
git add privet-storage/src/history.rs privet-storage/tests/path_guard_boundary.rs
git commit -m "feat(storage): persist source_path on transfer file completion"
```

---
---

### Task 3: Storage — `delete_history_entry`

**Files:**
- Modify: `privet-storage/src/history.rs`
- Test: `privet-storage/src/history.rs` (mod tests)

**Interfaces:**
- Consumes: nothing new.
- Produces: `pub fn delete_history_entry(conn: &rusqlite::Connection, transfer_id: &str) -> Result<(), StorageError>` — deletes one history row; `transfer_files` rows cascade via FK.

- [ ] **Step 1: Write the failing test**

Add to `mod tests` in `privet-storage/src/history.rs`:

```rust
#[test]
fn delete_history_entry_removes_transfer_and_files() {
    let conn = db();
    insert_history(&conn, &new_xfer("t1", None)).unwrap();
    complete_history(
        &conn,
        "t1",
        &[FileRow {
            file_id: "f1",
            relative_path: "a",
            size: 1,
            hash_type: "blake3".into(),
            hash_value: None,
            status: "completed",
            source_path: None,
        }],
        1,
    )
    .unwrap();
    delete_history_entry(&conn, "t1").unwrap();
    let h: i64 = conn
        .query_row("SELECT COUNT(*) FROM transfer_history", [], |r| r.get(0))
        .unwrap();
    let f: i64 = conn
        .query_row("SELECT COUNT(*) FROM transfer_files", [], |r| r.get(0))
        .unwrap();
    assert_eq!((h, f), (0, 0));
    // Deleting a missing id is a no-op, not an error.
    assert!(delete_history_entry(&conn, "does-not-exist").is_ok());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p privet-storage delete_history_entry_removes_transfer_and_files`
Expected: FAIL — `delete_history_entry` not found (compile error).

- [ ] **Step 3: Implement**

Add to `privet-storage/src/history.rs` (next to `clear_history`):

```rust
pub fn delete_history_entry(
    conn: &rusqlite::Connection,
    transfer_id: &str,
) -> Result<(), StorageError> {
    conn.execute(
        "DELETE FROM transfer_history WHERE transfer_id=?1",
        rusqlite::params![transfer_id],
    )?;
    Ok(())
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p privet-storage delete_history_entry_removes_transfer_and_files`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add privet-storage/src/history.rs
git commit -m "feat(storage): single-entry history deletion"
```

---
---

### Task 4: Storage — `get_history_detail` query

**Files:**
- Modify: `privet-storage/src/history.rs`
- Test: `privet-storage/src/history.rs` (mod tests)

**Interfaces:**
- Consumes: `insert_history`, `complete_history` (with `source_path`).
- Produces:

```rust
pub struct HistoryFileRow {
    pub relative_path: String,
    pub source_path: Option<String>,
    pub size: u64,
    pub status: String,
}

pub struct HistoryDetailRow {
    pub transfer_id: String,
    pub direction: String,
    pub peer_device_fingerprint: Option<String>,
    pub peer_name: Option<String>,
    pub root_name: Option<String>,
    pub status: String,
    pub started_ts: i64,
    pub finished_ts: Option<i64>,
    pub save_dir: Option<String>,
    pub files: Vec<HistoryFileRow>,
}

pub fn get_history_detail(
    conn: &rusqlite::Connection,
    transfer_id: &str,
) -> Result<Option<HistoryDetailRow>, StorageError>
```

- [ ] **Step 1: Write the failing test**

Add to `mod tests` in `privet-storage/src/history.rs`:

```rust
#[test]
fn get_history_detail_returns_summary_and_files() {
    let conn = db();
    // seed a completed receive with save_dir and two files
    let mut t = new_xfer("t1", None);
    t.save_dir = Some("/tmp/s");
    t.root_name = Some("docs");
    insert_history(&conn, &t).unwrap();
    complete_history(
        &conn,
        "t1",
        &[
            FileRow {
                file_id: "f1",
                relative_path: "a.txt",
                size: 10,
                hash_type: "blake3".into(),
                hash_value: Some("h1"),
                status: "completed",
                source_path: None,
            },
            FileRow {
                file_id: "f2",
                relative_path: "sub/b.txt",
                size: 20,
                hash_type: "blake3".into(),
                hash_value: Some("h2"),
                status: "completed",
                source_path: None,
            },
        ],
        999,
    )
    .unwrap();

    let row = get_history_detail(&conn, "t1").unwrap().unwrap();
    assert_eq!(row.transfer_id, "t1");
    assert_eq!(row.direction, "receive");
    assert_eq!(row.save_dir.as_deref(), Some("/tmp/s"));
    assert_eq!(row.root_name.as_deref(), Some("docs"));
    assert_eq!(row.status, "completed");
    assert_eq!(row.files.len(), 2);
    assert_eq!(row.files[0].relative_path, "a.txt");
    assert_eq!(row.files[0].size, 10);
    assert_eq!(row.files[1].relative_path, "sub/b.txt");

    assert!(get_history_detail(&conn, "missing").unwrap().is_none());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p privet-storage get_history_detail_returns_summary_and_files`
Expected: FAIL — `get_history_detail` not found (compile error).

- [ ] **Step 3: Implement**

Add the structs and function to `privet-storage/src/history.rs`. Add `use rusqlite::OptionalExtension;` at the top of the file:

```rust
pub struct HistoryFileRow {
    pub relative_path: String,
    pub source_path: Option<String>,
    pub size: u64,
    pub status: String,
}

pub struct HistoryDetailRow {
    pub transfer_id: String,
    pub direction: String,
    pub peer_device_fingerprint: Option<String>,
    pub peer_name: Option<String>,
    pub root_name: Option<String>,
    pub status: String,
    pub started_ts: i64,
    pub finished_ts: Option<i64>,
    pub save_dir: Option<String>,
    pub files: Vec<HistoryFileRow>,
}

pub fn get_history_detail(
    conn: &rusqlite::Connection,
    transfer_id: &str,
) -> Result<Option<HistoryDetailRow>, StorageError> {
    let summary = conn
        .query_row(
            "SELECT transfer_id, direction, peer_device_fingerprint, peer_name, root_name, status,
                    started_ts, finished_ts, save_dir
             FROM transfer_history WHERE transfer_id=?1",
            rusqlite::params![transfer_id],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, String>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, Option<i64>>(7)?,
                    r.get::<_, Option<String>>(8)?,
                ))
            },
        )
        .optional()?;
    let Some((
        transfer_id,
        direction,
        peer_device_fingerprint,
        peer_name,
        root_name,
        status,
        started_ts,
        finished_ts,
        save_dir,
    )) = summary
    else {
        return Ok(None);
    };

    let mut stmt = conn.prepare(
        "SELECT relative_path, source_path, size, status FROM transfer_files
         WHERE transfer_id=?1 ORDER BY relative_path, file_id",
    )?;
    let files = stmt
        .query_map(rusqlite::params![transfer_id], |r| {
            Ok(HistoryFileRow {
                relative_path: r.get(0)?,
                source_path: r.get(1)?,
                size: r.get::<_, i64>(2)? as u64,
                status: r.get(3)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;

    Ok(Some(HistoryDetailRow {
        transfer_id,
        direction,
        peer_device_fingerprint,
        peer_name,
        root_name,
        status,
        started_ts,
        finished_ts,
        save_dir,
        files,
    }))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p privet-storage get_history_detail_returns_summary_and_files`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add privet-storage/src/history.rs
git commit -m "feat(storage): history detail query joins transfer and files"
```

---
---

### Task 5: Core — `history_detail` and `delete_history` engine methods

**Files:**
- Modify: `privet-core/src/ops.rs` (near `history`, ~line 33)
- Test: `privet-core/tests/ops_read.rs`

**Interfaces:**
- Consumes: `history::get_history_detail`, `history::delete_history_entry`, `FileRow.source_path`.
- Produces:

```rust
pub fn history_detail(&self, transfer_id: &str) -> crate::Result<Option<history::HistoryDetailRow>>
pub fn delete_history(&self, transfer_id: &str) -> crate::Result<()>
```

- [ ] **Step 1: Write the failing tests**

Add a seed helper plus three tests to `privet-core/tests/ops_read.rs` (reusing the file's existing `engine()` helper):

```rust
fn seed_completed_send(e: &Engine) {
    let conn = e.db_conn().unwrap();
    privet_storage::history::insert_history(
        &conn,
        &privet_storage::history::NewTransfer {
            transfer_id: "t-send",
            direction: privet_storage::history::TransferDirection::Send,
            peer_device_fingerprint: None,
            peer_name: Some("peer"),
            root_name: Some("docs"),
            file_count: 1,
            total_bytes: 10,
            status: privet_storage::history::TransferStatus::Completed,
            started_ts: 1,
            save_dir: None,
            send_intent: "{\"paths\":[\"/home/u/docs\"],\"chunk_size\":1048576,\"segment_max_chunks\":1024}",
        },
    )
    .unwrap();
    privet_storage::history::complete_history(
        &conn,
        "t-send",
        &[privet_storage::history::FileRow {
            file_id: "f1",
            relative_path: "a.txt",
            size: 10,
            hash_type: "blake3".into(),
            hash_value: Some("h"),
            status: "completed",
            source_path: Some("/home/u/docs/a.txt"),
        }],
        2,
    )
    .unwrap();
}

#[test]
fn history_detail_returns_none_for_unknown_transfer() {
    let (e, _d) = engine();
    assert!(e.history_detail("missing").unwrap().is_none());
}

#[test]
fn history_detail_returns_seeded_files_and_source_path() {
    let (e, _d) = engine();
    seed_completed_send(&e);
    let detail = e.history_detail("t-send").unwrap().unwrap();
    assert_eq!(detail.direction, "send");
    assert_eq!(detail.files.len(), 1);
    assert_eq!(detail.files[0].relative_path, "a.txt");
    assert_eq!(detail.files[0].source_path.as_deref(), Some("/home/u/docs/a.txt"));
}

#[test]
fn delete_history_removes_the_entry() {
    let (e, _d) = engine();
    seed_completed_send(&e);
    e.delete_history("t-send").unwrap();
    assert!(e.history_detail("t-send").unwrap().is_none());
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p privet-core history_detail_returns_none_for_unknown_transfer`
Expected: FAIL — `history_detail` not found (compile error).

- [ ] **Step 3: Implement the engine methods**

Add to `privet-core/src/ops.rs`, immediately after the existing `history` method:

```rust
    pub fn history_detail(
        &self,
        transfer_id: &str,
    ) -> crate::Result<Option<history::HistoryDetailRow>> {
        let db = self.db_conn()?;
        Ok(history::get_history_detail(&db, transfer_id)?)
    }

    pub fn delete_history(&self, transfer_id: &str) -> crate::Result<()> {
        let db = self.db_conn()?;
        Ok(history::delete_history_entry(&db, transfer_id)?)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p privet-core history_detail_returns_none_for_unknown_transfer history_detail_returns_seeded_files_and_source_path delete_history_removes_the_entry`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add privet-core/src/ops.rs privet-core/tests/ops_read.rs
git commit -m "feat(core): history_detail and delete_history engine methods"
```

---
---

### Task 6: Core — persist `source_path` on send completion

**Files:**
- Modify: `privet-core/src/ops.rs:539-550` (the `complete_history` FileRow loop in `do_send_inner`)
- Test: `privet-core/tests/ops_send_serve.rs` (extend `send_to_serve_lands_file_over_quic`)

**Interfaces:**
- Consumes: `PreparedFile.abs_path` (already present), `FileRow.source_path`.
- Produces: after a completed real send, `transfer_files.source_path` holds the canonical source path, observable via `Engine::history_detail`.

- [ ] **Step 1: Write the failing assertion**

In `privet-core/tests/ops_send_serve.rs`, extend `send_to_serve_lands_file_over_quic` (after the existing history check, before `serve.shutdown()`):

```rust
    // History detail exposes the canonical send source path.
    let detail = sender
        .history_detail(&outcome.transfer_id)
        .unwrap()
        .expect("completed send has a detail row");
    let expected_src = src.canonicalize().unwrap().to_string_lossy().into_owned();
    assert_eq!(
        detail.files[0].source_path.as_deref(),
        Some(expected_src.as_str()),
        "send detail source_path must be the canonical source path"
    );
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p privet-core send_to_serve_lands_file_over_quic`
Expected: FAIL — `detail.files[0].source_path` is `None` (the ops.rs loop has not been updated yet).

- [ ] **Step 3: Update the send completion FileRow loop**

In `privet-core/src/ops.rs`, `do_send_inner`, replace the `files` mapping:

```rust
        let files: Vec<privet_storage::history::FileRow> = prepared
            .files
            .iter()
            .map(|f| privet_storage::history::FileRow {
                file_id: &f.file_id,
                relative_path: &f.relative_path,
                size: f.size,
                hash_type: "blake3".into(),
                hash_value: Some(&f.file_hash),
                status: "completed",
                source_path: Some(&*f.abs_path.to_string_lossy()),
            })
            .collect();
```

> `f.abs_path` is `PathBuf`; `to_string_lossy()` yields a `Cow<'_, str>` borrowing from the path, so `&*...` coerces to `&str` with `f`'s lifetime — matching `FileRow`'s `Option<&'a str>` field.

- [ ] **Step 4: Run the workspace storage + core tests to verify they pass**

Run: `cargo test -p privet-storage -p privet-core`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add privet-core/src/ops.rs privet-core/tests/ops_send_serve.rs
git commit -m "feat(core): persist send source_path at completion"
```

---
---

### Task 7: IPC — protocol additions

**Files:**
- Modify: `privet-ipc/src/protocol.rs` (Request enum, ResponsePayload enum, new DTOs)
- Test: `privet-ipc/src/protocol.rs` (mod tests)

**Interfaces:**
- Consumes: existing serde conventions.
- Produces:

```rust
// Request variants:
GetHistoryDetail { transfer_id: String },
DeleteHistory { transfer_id: String },

// ResponsePayload variant:
HistoryDetail(HistoryDetailDto),

// New DTOs:
pub struct HistoryFileDto {
    pub relative_path: String,
    pub absolute_path: Option<String>,
    pub size: u64,
    pub status: String,
}
pub struct HistoryDetailDto {
    pub transfer_id: String,
    pub direction: String,
    pub peer_device_fingerprint: Option<String>,
    pub peer_name: Option<String>,
    pub root_name: Option<String>,
    pub status: String,
    pub started_ts: i64,
    pub finished_ts: Option<i64>,
    pub files: Vec<HistoryFileDto>,
}
```

- [ ] **Step 1: Write the failing test**

Add to `mod tests` in `privet-ipc/src/protocol.rs`:

```rust
#[test]
fn get_history_detail_round_trip_is_stable() {
    let request = Request::GetHistoryDetail { transfer_id: "t-1".into() };
    let message = ClientMessage { protocol_version: IPC_PROTOCOL_VERSION, request_id: "req-1".into(), request };
    let encoded = serde_json::to_vec(&message).unwrap();
    let decoded: ClientMessage = serde_json::from_slice(&encoded).unwrap();
    assert_eq!(decoded, message);
}

#[test]
fn history_detail_dto_round_trip_is_stable() {
    let dto = HistoryDetailDto {
        transfer_id: "t-1".into(),
        direction: "receive".into(),
        peer_device_fingerprint: None,
        peer_name: Some("p".into()),
        root_name: Some("docs".into()),
        status: "completed".into(),
        started_ts: 1,
        finished_ts: Some(2),
        files: vec![HistoryFileDto {
            relative_path: "a.txt".into(),
            absolute_path: Some("C:\\received\\docs\\a.txt".into()),
            size: 10,
            status: "completed".into(),
        }],
    };
    let payload = ResponsePayload::HistoryDetail(dto);
    let encoded = serde_json::to_vec(&payload).unwrap();
    let decoded: ResponsePayload = serde_json::from_slice(&encoded).unwrap();
    assert_eq!(decoded, payload);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p privet-ipc get_history_detail_round_trip_is_stable`
Expected: FAIL — `GetHistoryDetail` not found (compile error).

- [ ] **Step 3: Implement**

In `privet-ipc/src/protocol.rs`:

1. Add to the `Request` enum (before `SubscribeEvents`):

```rust
    GetHistoryDetail { transfer_id: String },
    DeleteHistory { transfer_id: String },
```

2. Add to the `ResponsePayload` enum:

```rust
    HistoryDetail(HistoryDetailDto),
```

3. Add the DTOs (after `HistoryEntryDto`):

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HistoryFileDto {
    pub relative_path: String,
    pub absolute_path: Option<String>,
    pub size: u64,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HistoryDetailDto {
    pub transfer_id: String,
    pub direction: String,
    pub peer_device_fingerprint: Option<String>,
    pub peer_name: Option<String>,
    pub root_name: Option<String>,
    pub status: String,
    pub started_ts: i64,
    pub finished_ts: Option<i64>,
    pub files: Vec<HistoryFileDto>,
}
```

> Note the JSON shape: `ResponsePayload` is internally tagged `{"kind": "history_detail", "data": {...}}`. The `HistoryFileDto.absolute_path` is `Option<String>` because pre-migration send records have no `source_path`.

- [ ] **Step 4: Run the ipc tests to verify they pass**

Run: `cargo test -p privet-ipc`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add privet-ipc/src/protocol.rs
git commit -m "feat(ipc): get_history_detail and delete_history requests and DTOs"
```

---
---

### Task 8: Daemon — handle `GetHistoryDetail` and `DeleteHistory`

**Files:**
- Modify: `privet-daemon/src/backend.rs` (match arms + `history_detail_dto` mapping)
- Test: `privet-daemon/src/backend.rs` (new `#[cfg(test)] mod tests`)

**Interfaces:**
- Consumes: `engine.history_detail`, `engine.delete_history`, `HistoryDetailDto`, `HistoryFileDto`.
- Produces: two handled requests; a pure `fn history_detail_dto(row: privet_storage::history::HistoryDetailRow) -> HistoryDetailDto` that computes `absolute_path`:
  - direction `send` → `file.source_path`
  - otherwise → `save_dir / root_name? / relative_path` (mirrors `receiver.rs::final_landing_path`).

- [ ] **Step 1: Write the failing tests**

Add a `mod tests` to `privet-daemon/src/backend.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use privet_storage::history::{HistoryDetailRow, HistoryFileRow};

    #[test]
    fn history_detail_dto_maps_send_source_path() {
        let row = HistoryDetailRow {
            transfer_id: "t1".into(),
            direction: "send".into(),
            peer_device_fingerprint: None,
            peer_name: Some("peer".into()),
            root_name: Some("docs".into()),
            status: "completed".into(),
            started_ts: 1,
            finished_ts: Some(2),
            save_dir: None,
            files: vec![HistoryFileRow {
                relative_path: "a.txt".into(),
                source_path: Some("/home/u/docs/a.txt".into()),
                size: 10,
                status: "completed".into(),
            }],
        };
        let dto = history_detail_dto(row);
        assert_eq!(dto.files[0].absolute_path.as_deref(), Some("/home/u/docs/a.txt"));
    }

    #[test]
    fn history_detail_dto_maps_receive_landed_path() {
        let row = HistoryDetailRow {
            transfer_id: "t2".into(),
            direction: "receive".into(),
            peer_device_fingerprint: None,
            peer_name: None,
            root_name: Some("docs".into()),
            status: "completed".into(),
            started_ts: 1,
            finished_ts: Some(2),
            save_dir: Some("/tmp/s".into()),
            files: vec![HistoryFileRow {
                relative_path: "a.txt".into(),
                source_path: None,
                size: 10,
                status: "completed".into(),
            }],
        };
        let dto = history_detail_dto(row);
        let expected = std::path::PathBuf::from("/tmp/s").join("docs").join("a.txt");
        assert_eq!(dto.files[0].absolute_path.as_deref(), Some(expected.to_string_lossy().as_ref()));
    }

    #[test]
    fn history_detail_dto_receive_without_root_uses_save_dir_only() {
        let row = HistoryDetailRow {
            transfer_id: "t3".into(),
            direction: "receive".into(),
            peer_device_fingerprint: None,
            peer_name: None,
            root_name: None,
            status: "completed".into(),
            started_ts: 1,
            finished_ts: None,
            save_dir: Some("/tmp/s".into()),
            files: vec![HistoryFileRow {
                relative_path: "a.txt".into(),
                source_path: None,
                size: 10,
                status: "completed".into(),
            }],
        };
        let dto = history_detail_dto(row);
        let expected = std::path::PathBuf::from("/tmp/s").join("a.txt");
        assert_eq!(dto.files[0].absolute_path.as_deref(), Some(expected.to_string_lossy().as_ref()));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p privet-daemon history_detail_dto`
Expected: FAIL — `history_detail_dto` not found.

- [ ] **Step 3: Implement the handlers and mapping**

Add match arms in `handle` (after the `ListHistory` arm):

```rust
            Request::GetHistoryDetail { transfer_id } => {
                let row = self
                    .engine
                    .history_detail(&transfer_id)?
                    .ok_or_else(|| BackendError::invalid("transfer not found"))?;
                Ok(ResponsePayload::HistoryDetail(history_detail_dto(row)))
            }
            Request::DeleteHistory { transfer_id } => {
                self.engine.delete_history(&transfer_id)?;
                Ok(ResponsePayload::Ack)
            }
```

Add the mapping function next to `history_dto`:

```rust
fn history_detail_dto(row: privet_storage::history::HistoryDetailRow) -> HistoryDetailDto {
    let files = row
        .files
        .iter()
        .map(|f| {
            let absolute_path = if row.direction == "send" {
                f.source_path.clone()
            } else {
                let mut path = std::path::PathBuf::new();
                if let Some(dir) = &row.save_dir {
                    path.push(dir);
                }
                if let Some(root) = &row.root_name {
                    path.push(root);
                }
                path.push(&f.relative_path);
                Some(path.to_string_lossy().into_owned())
            };
            HistoryFileDto {
                relative_path: f.relative_path.clone(),
                absolute_path,
                size: f.size,
                status: f.status.clone(),
            }
        })
        .collect();
    HistoryDetailDto {
        transfer_id: row.transfer_id,
        direction: row.direction,
        peer_device_fingerprint: row.peer_device_fingerprint,
        peer_name: row.peer_name,
        root_name: row.root_name,
        status: row.status,
        started_ts: row.started_ts,
        finished_ts: row.finished_ts,
        files,
    }
}
```

- [ ] **Step 4: Run the daemon tests to verify they pass**

Run: `cargo test -p privet-daemon`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add privet-daemon/src/backend.rs
git commit -m "feat(daemon): get_history_detail and delete_history IPC handlers"
```

---
---

### Task 9: Documentation — update `SPECIFICATIONS/09` and `07`

**Files:**
- Modify: `SPECIFICATIONS/09-daemon-ipc.md`
- Modify: `SPECIFICATIONS/07-storage.md`

**Interfaces:**
- Consumes: everything from Tasks 1–8.

- [ ] **Step 1: Update `09-daemon-ipc.md`**

1. In the Requests table (§5), add two rows:

```markdown
| `get_history_detail` | transfer ID | history detail with per-file absolute paths |
| `delete_history` | transfer ID | ack |
```

2. In the Response data section (§6), add to the implemented variants list: `history_detail`.

3. Add a short paragraph after the `History` bullet describing the detail payload (per-file `relative_path`, `absolute_path`, `size`, `status`; `absolute_path` is the send source path or the receive `save_dir/root/relative` landed path, and is `null` when a send record predates schema v2).

- [ ] **Step 2: Update `07-storage.md`**

Add a schema-change note: `transfer_files.source_path` (nullable, migration v2), and describe `get_history_detail` / `delete_history_entry` as the query surfaces. Update any "Current limitations" text that claims history detail is unavailable.

- [ ] **Step 3: Run the full workspace checks**

Run:
```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --all-targets
```
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add SPECIFICATIONS/09-daemon-ipc.md SPECIFICATIONS/07-storage.md
git commit -m "docs(spec): history detail and delete IPC methods"
```

---
---

### Task 10: End-to-end verification

**Files:** none (manual verification script).

- [ ] **Step 1: Run a real send and inspect detail**

Start the daemon against a scratch config (see `privet.example.json`), send a small directory with a second privet client (or a `privet-ipc` smoke script calling `Send` then `GetHistoryDetail`), and confirm:
- `GetHistoryDetail` returns one file row per sent file with a correct `absolute_path` (the send source path).
- `DeleteHistory` removes the row and `GetHistoryDetail` then errors with `invalid_request` / "transfer not found".

- [ ] **Step 2: Confirm receive-side detail**

Receive a transfer into a scratch `save_dir`, then confirm `GetHistoryDetail` reports `absolute_path` = `save_dir/root_name/relative_path` for each landed file, and that `Open file` (future GUI) resolves.

- [ ] **Step 3: Report results**

Record the observed DTOs (redact any real paths) in the plan's execution notes. If either direction misbehaves, open a follow-up using superpowers:systematic-debugging.
