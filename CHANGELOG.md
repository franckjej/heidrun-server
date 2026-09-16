# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/); the
project adheres to [Semantic Versioning](https://semver.org/). Pre-1.0
development happened on the `1.0.0-rcN` tag series.

## [1.5.1] — 2026-09-16

### Fixed
- **Single-file downloads always ship the flattened file object.** The server
  sent a bare data fork unless the Heidrun-only `resourceForkSupport` flag was
  negotiated, so classic clients (and Heidrun ≤ 1.4 against classic servers)
  misread downloads. Fresh downloads, resumes (data-fork remainder + full
  resource fork) and large files now all frame per the Hotline spec; the flag
  is a no-op.

## [1.5.0] — 2026-09-09

### Added
- **Drop boxes and upload folders.** Folders named `…upload…` / `…drop box…`
  now carry their classic Hotline roles. `viewDropBoxes` gates every read and
  mutation inside a drop box; `uploadAnywhere` limits uploads to upload
  folders and drop boxes. Existing accounts with *Upload Files* but not
  *Upload Anywhere* lose upload access to plain folders — see
  `docs/OPERATIONS.md` → "Drop boxes and upload folders".

### Changed
- **Docker image:** builder is `swift:6.3.3-noble`; binaries link the Swift
  stdlib statically and run on plain `ubuntu:noble`, which is `apt-get
  upgrade`d at build time.
- **Makefile:** `make build / test / lint / test-linux / up / down / logs`,
  plus `make refresh` — rebuilds the image without the layer cache so the OS
  packages inside it are current. Meant for a weekly cron
  (`docs/OPERATIONS.md`).

### Notes
- Pins `heidrun-protocol` **1.1.0** (adds `FolderRole`).

## [1.4.0] — 2026-06-21

### Added
- **Large-file transfers (> 4 GiB).** Single-file and folder downloads/uploads
  now exceed the old 4 GiB cap when the client negotiates `CAPABILITY_LARGE_FILES`:
  64-bit sizes, the 24-byte HTXF handshake, 64-bit fork headers, and an 8-byte
  per-item size prefix in folder streams. Legacy clients are unaffected
  (32-bit, byte-identical).
- **UTF-8 text encoding.** When a client negotiates `CAPABILITY_TEXT_ENCODING`,
  the session uses UTF-8 for all strings (chat, nicknames, file/folder names,
  comments, news, topic) — so emoji and non-Latin scripts work. The login
  nickname is decoded UTF-8 when advertised in the login packet; the session
  flips after the login reply. Non-negotiating clients stay on macOS Roman.

### Fixed
- **> 4 GiB framed downloads no longer crash.** The download envelope is now
  streamed in chunks (NIO's `ByteBuffer` is bounded to 32-bit indices), and
  fork lengths thread through as `UInt64`.

### Notes
- Pins `heidrun-protocol` **1.0.0** (graduated from the rc series).
- Known limitation: broadcasts are encoded once per the broadcasting session's
  encoding — fully correct for an all-UTF-8 client population; a mixed
  population with a legacy (non-UTF-8) client present can mis-render non-ASCII
  broadcast content. Per-recipient broadcast encoding is a planned follow-up.

## [1.3.0] — 2026-06-21

### Added
- **`heidrun-admin log --table` ACCOUNT + ADMIN columns** — the login the user
  signed on with, and the account's admin flag (`true`/`false`). The server now
  logs `login` + `isAdmin` on the per-transaction `dispatch` line (masked
  pre-login), so both columns populate on every row.
- **`-n` short alias for `--lines`** on `heidrun-admin log` (tail-style).

### Fixed
- **Connection-shutdown race.** `stop()` now closes live connections and waits
  for their per-connection session tasks to finish before tearing down the
  event-loop group. This eliminates the NIO "Cannot schedule tasks on an
  EventLoop that has already shut down" errors (and the warned-of future forced
  crash), and makes the SIGTERM shutdown path clean.

Pins heidrun-protocol `1.0.0-rc20`. Distribution: Docker + build-from-source.

## [1.2.1] — 2026-06-21

### Added
- **`heidrun-admin log --date`** — include the full date
  (`yyyy-MM-dd HH:mm:ss`) in log timestamps, in both the line and `--table`
  views; without the flag the timestamp is time-of-day only as before.

Pins heidrun-protocol `1.0.0-rc20`. Distribution: Docker + build-from-source.

## [1.2.0] — 2026-06-21

Adds a tabular view for `heidrun-admin log`.

### Added
- **`heidrun-admin log --table`** — a fixed-width tabular output mode for the
  unified log stream, with one column per field
  (`TIME · S · LVL · HOST · NICK · TLS · TRANS · SOCK · TASK · FLDS · ACTION`)
  instead of one free-form line per record. The `ACTION` column resolves a
  per-transaction `dispatch` row's numeric transaction id to a name (a row with
  `TRANS` 107 shows `login`); other rows show their message or audit
  description. The protocol columns (`TRANS`/`SOCK`/`TASK`/`FLDS`) ride the
  debug-level `dispatch` line — pass `--level debug` to populate them. Mutually
  exclusive with `--json`.

Pins heidrun-protocol `1.0.0-rc20`. Distribution: Docker + build-from-source.

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
