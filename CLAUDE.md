# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**HeidrunServer** — a Swift 6, pure-SwiftNIO Hotline-protocol server. Pairs with the [Heidrun](https://github.com/franckjej/heidrun-swift) macOS client (or any classic Hotline 1.x client) and runs on macOS and Linux from the same source. Repo: `franckjej/heidrun-server`, work branch `main`.

The Hotline wire types and codecs live in the shared SPM package `franckjej/heidrun-protocol` (product `HeidrunCore`), which both the client and this server consume. Edits to the wire format happen there, not here.

**Do not push to `origin/main` without explicit user confirmation.** Local commits on this branch are typically ahead of the remote until the user pushes themselves.

## Repo layout

```
Package.swift                       SPM manifest — products + deps
Sources/
  HeidrunServer/                    @main executable; thin shim around HeidrunServerKit
  HeidrunServerKit/                 the actual server: actors, handlers, persistence, TLS, tracker
Tests/
  HeidrunServerKitTests/            Swift Testing suites + TestCerts/ resource bundle
heidrun-server.example.toml         annotated sample config
Dockerfile, docker-compose.yml      production container build
deploy/
  systemd/heidrun-server.service    Linux unit file
  launchd/org.tastybytes.heidrun-server.plist  macOS LaunchDaemon
```

## Commands

This is a pure SwiftPM project — **no Xcode project, no XcodeBuildMCP**. Use `swift` directly.

All commands run from the repo root.

```bash
# Build & run locally (defaults to 127.0.0.1:5500 control, :5501 HTXF)
swift run HeidrunServer

# Build only
swift build

# Tests (Swift Testing — #expect / #require, not XCTest)
swift test
swift test --filter HeidrunServerKitTests.AccountStoreTests   # single suite

# Resolve / refresh the heidrun-protocol package
swift package resolve

# Docker build
docker build -t heidrun-server .

# Docker compose
docker compose up -d --build
```

## Architecture

### Top-level actor: `HeidrunServer`

`Sources/HeidrunServerKit/HeidrunServer.swift` is the lifecycle actor. `start()` binds the control listener on `port` and the HTXF transfer listener on `port + 1`, optionally a TLS-wrapped sibling pair on `tls_port` / `tls_port + 1`. It owns the shared stores (`AccountStore`, `FileVault`, `FileMetadataStore`, `NewsTree`, `UserRegistry`, `TransferRegistry`, `PrivateChatRegistry`, optional `TrackerAnnouncer`) and hands them to each new `ClientSession`. `stop()` drains sessions and closes listeners.

### Per-connection: `ClientSession`

One `ClientSession` actor per accepted TCP socket. The NIO channel just feeds raw bytes into an `AsyncStream<Data>` via `SessionIOHandler` (in `ByteStream.swift`); the session reads packets in a `for await` loop, decodes them with `HeidrunCore` types, and dispatches by transaction ID. Handlers are split by category across `ClientSession+*.swift` files:

- `+Admin.swift` — createLogin / deleteLogin / openLogin / modifyLogin
- `+Files.swift` — list, info, download, upload, delete, mkdir, rename, move, alias
- `+PlainNews.swift`, `+ThreadedNews.swift` — both news subsystems
- `+PrivateChats.swift`, `+PrivateMessages.swift` — 1-on-1 chat + DM routing
- `+Banner.swift` — transID 212 banner replies
- `+Misc.swift` — kick, user info, agreement

Replies are built with `PacketEncoder.swift` static builders (each returns `Data` ready to write).

### Persistence

- **`AccountStore`** (GRDB actor) — `accounts` table with PBKDF2-SHA256 hashed passwords (~210k rounds prod, tiny in tests). Runs the `v1_accounts` migration on init.
- **`FileMetadataStore`** (GRDB actor, same SQLite file) — `file_metadata` table keyed by **path relative to `files_root`**, holding HFS type/creator + comments. Decoupling metadata from the file tree means the tree can live on a separate volume.
- **`FileVault`** (actor) — Foundation-backed file ops against `files_root`. No in-band versioning; operators manage backups.
- **`NewsTree`** (actor) — plain news as `[String]`, threaded news as a `[BundleNode]` tree. Persists atomically as JSON to `news_state_path` (auto-derived to `<db_path>.news.json` if unset; empty string disables).

### Network surface area

- **Control channel**: bare NIO `ServerBootstrap`; no custom NIO codecs — `SessionIOHandler` just streams reads.
- **HTXF transfer side-channel** (port + 1): `TransferRegistry` issues 32-bit transferIDs that clients quote in their HTXF handshake; `ServerFolderUpload` / `ServerFolderDownload` drive the folder framing.
- **TLS**: optional, all-or-nothing. `TLSContextBuilder` builds the NIOSSL context from PEM cert chain + key. If `tls_port` is set but cert/key paths are missing or unreadable, startup **fails fast** rather than silently reverting to cleartext.
- **Tracker**: `TrackerAnnouncer` sends one mobius-compatible UDP packet to each configured tracker every 5 minutes; failures are logged + skipped.

### Idle-away supervisor

If `idle_away_threshold` > 0, a supervisor task walks the live `UserRegistry` every `idle_away_poll_interval` seconds and flips `UserStatusFlags.away` on sessions that haven't sent a packet in `idle_away_threshold` seconds, broadcasting `userChanged` so peers dim that row. Next inbound packet clears it.

## Hotline wire-protocol gotchas

These live in `heidrun-protocol` (`HeidrunCore`), but you'll trip over them on this side too. The original Obj-C reference is `legacy/.../HEClient.m` in the `heidrun-swift` checkout.

- **All multi-byte ints are big-endian.**
- **String encoding** defaults to `.macOSRoman`.
- **Login/password obfuscation** = XOR every byte with `0xFF`. Applied to login(105) and password(106) on auth + account-admin transactions **except `openLogin` (352) where login goes plain**.
- **Path encoding** (objIDs 202, 212, 325): `UInt16 componentCount` + per-component `(UInt16 0 pad, UInt8 length, name bytes)`.
- **HTXF handshake variants**: file download is `"HTXF"` + UInt32 transferID + UInt32 transferSize + UInt32 reserved (0). Folder upload swaps the trailing 4 bytes for `UInt16 1, 0`. Folder download is 18 bytes adding a `UInt16 3` sentinel.
- **Hotline timestamps** = seconds since `1904-01-01 00:00:00 UTC` (classic Mac epoch).
- **`modifyLogin` password convention**: `password: String?` — `nil` omits the field (legacy `noPass`), `""` sends a single `0x00` byte (legacy `emptyPass`).
- **File upload framing**: `FILP` 40-byte header (forkCount=3) → `INFO` block (74 + nameLen) with HFS type/creator + 1904-epoch dates + name → `DATA` fork hdr (16 B) + data fork → `MACR` fork hdr (16 B; resource fork dropped on the wire — modern macOS doesn't use them).

### Testing pattern

Tests use **Swift Testing** (`#expect`, `#require`), not XCTest. Network-level suites typically spin up a `HeidrunServer` instance bound to `127.0.0.1:0` (kernel-assigned port) with an in-memory DB + tempdir files root, then drive it with raw `NWConnection` clients or `HeidrunCore` codecs. TLS suites consume PEMs from the `TestCerts/` resource bundle (access via `Bundle.module`). Password hashing in tests uses a tiny round count so suites stay fast.

## Configuration

`heidrun-server.example.toml` is the annotated source of truth for the config surface; `ServerConfigurationFile.swift` does the TOML decode and env-var overlay. **Precedence: env vars > TOML file > built-in defaults.** Env-var names mirror keys (`HEIDRUN_PORT`, `HEIDRUN_TLS_CERTIFICATE`, …).

Sections at a glance:
- network: `port`, `bind_host`, `tls_port`, `tls_certificate`, `tls_private_key`
- identity: `server_name`, `agreement`, `banner_path`, `banner_kind`
- persistence: `db_path`, `files_root`, `news_state_path`
- bootstrap: `[bootstrap_admin]` (seeded only on an empty accounts table)
- tracker: `trackers = [...]`, `tracker_description`
- supervisor: `idle_away_threshold`, `idle_away_poll_interval`
- logging: `log_level` (`HEIDRUN_LOG_LEVEL`)

## Code style

<important>
**Identifiers must be descriptive and at least 3 characters long.** This applies to local variables, properties, function parameters, closure parameters, case-binding names, and tuple element labels. Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) — clarity at the point of use wins over brevity.

- ❌ `let fm = FileManager.default` / `let s = session` / `case .failure(let e):` / `{ s in ... }`
- ✅ `let fileManager = FileManager.default` / `let clientSession = ...` / `case .failure(let error):` / `{ socket in ... }`

**Narrow exemptions** (the only short names that are allowed):
- Generic type parameters: `T`, `U`, `V`, `Element`, `Failure`. Single uppercase letters are the Swift idiom here.
- Anonymous closure shorthand: `$0`, `$1`.
- The Swift argument *label* `id:` (e.g. `ForEach(items, id: \.self)`) — the *label* stays `id`; any internal parameter name must still be ≥ 3 chars.
- Math/coordinate variables in tight scopes where the meaning is obvious from context: `x`, `y`, `z` for a `CGPoint`/`SIMD` component, or a loop counter `i`/`j` in a 1–2 line numeric loop. When in doubt, expand.

Apply this when writing new code and when touching existing code — rename short identifiers in any file you modify.
</important>

## Open work

Named, deferred work — keep these in mind when touching the relevant area:

- **TLS renewal hooks.** The server reads cert + key at bind time and holds the NIOSSL context for the lifetime of the listener. Cert rotation today requires a process restart. A proper SIGHUP-driven reload (or a watcher on the PEM paths) is the eventual fix.
- **Resource forks are intentionally dropped on the wire.** Both ends agree; modern macOS doesn't use resource forks. Round-tripping legacy archives that need them is an out-of-band conversion problem.
- **No HTXF backpressure.** Each session runs the read loop synchronously; large concurrent transfers won't yield to the control channel. Fine for current load — revisit if real deployments start saturating links.
