# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/); the
project adheres to [Semantic Versioning](https://semver.org/). Pre-1.0
development happened on the `1.0.0-rcN` tag series.

## [1.1.0] — 2026-06-20

Adds a native way to watch server activity without `docker logs`.

### Added
- **Operational-log file sink** — the server now mirrors its operational log
  (the same lines it prints to stderr / `docker logs`) into a rotating NDJSON
  file beside the database (`<db_path>.oplog.ndjson`), so admins can read it
  off the shared volume. stderr output is unchanged. Size-based rotation
  (default 10 MB × 5 archives). Config keys `operational_log_enabled`,
  `operational_log_path`, `operational_log_max_bytes`, `operational_log_keep`
  (env `HEIDRUN_OP_LOG_*`).
- **`heidrun-admin log`** — a `tail` / `tail -f` for server activity that
  merges the structured audit events with the operational log into one
  timestamp-ordered stream. Flags: `-f/--follow`, `--lines`,
  `--source audit|op|both`, `--account`, `--level`, `--type`, `--interval`,
  `--op-log-path`, `--json`. Each line surfaces the client `host:port` and the
  `tls` flag as columns.

### Changed
- The operational-log file sink is **on by default**, so a fresh start writes
  a new `<db_path>.oplog.ndjson` on the data volume. Like `docker logs`, this
  file includes client **IP addresses** and retains them across rotated
  archives — independent of the audit log's `log_ip_addresses` setting (which
  stays off by default). Set `operational_log_enabled = false`
  (env `HEIDRUN_OP_LOG_ENABLED=off`) to disable; `heidrun-admin log` then
  streams audit events only. See `docs/OPERATIONS.md`.

Pins heidrun-protocol `1.0.0-rc20`. Distribution: Docker + build-from-source.

## [1.0.0] — 2026-06-19

First stable release of HeidrunServer — a from-scratch Hotline-protocol
server in pure SwiftNIO that builds and runs on macOS and Linux from the same
source.

### Highlights
- **Hotline protocol** — public and private chat, the user list, threaded and
  flat news, the file browser, and the HTXF transfer side-channel (uploads,
  downloads, folder transfers, resume, resource forks).
- **Accounts & privileges** — persistent accounts (GRDB/SQLite) with
  per-account privilege enforcement across chat, files, news, and admin.
- **TLS** — optional TLS sibling-listener pair for the control and transfer
  channels.
- **Discovery** — UDP tracker registration and server banner push.
- **Chat slash commands** — `/version`, `/who`, `/topic`, `/broadcast`,
  `/kick`, `/usershistory`, and more.
- **Audit log** — opt-in presence / transfer / auth / admin logging in a
  separate SQLite file, queryable from the admin CLI.
- **heidrun-admin CLI** — direct-to-DB administration (`account`, `audit`,
  `news`, `db`). Runs in-container or natively on the host against a bind
  mount, with drop-to-DB-owner when run as root and no-flags config
  resolution.

### Fixed since the release-candidate series
- Threaded-news create/delete now reply on success, so clients no longer hang
  after creating a news folder/category or deleting a bundle/thread.
- `heidrun-admin` derives the audit / news / files paths from the database
  location and needs no flags in a typical deployment.
- Corrected the advertised version string (was stale at `0.7.0`).
- Silenced a `NIOSSL` Sendable warning under stricter swift-nio-ssl versions.

Pins heidrun-protocol `1.0.0-rc20`. Distribution: Docker + build-from-source.
