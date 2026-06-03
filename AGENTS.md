# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Cursor, Aider, …) working in this repo.

For project-facing detail (features, install, config, slash commands) see [`README.md`](README.md). For operator depth (TLS, Let's Encrypt, tracker debugging, banner serving) see [`docs/OPERATIONS.md`](docs/OPERATIONS.md). This file is what an agent needs *additionally* to do useful work.

## What this is

**HeidrunServer** — a Swift 6, pure-SwiftNIO Hotline-protocol server. Pairs with the [Heidrun](https://github.com/franckjej/heidrun) macOS client (or any classic Hotline 1.x client). Runs on macOS and Linux from the same source. Repo: `franckjej/heidrun-server`, work branch `main`.

Wire types and codecs live in the shared SPM package [`franckjej/heidrun-protocol`](https://github.com/franckjej/heidrun-protocol) (product `HeidrunCore`). **Edits to the wire format happen there, not here.**

**Do not push to `origin/main` without explicit user confirmation.** Local commits are typically ahead of the remote until the user pushes themselves.

## Repo layout

```
Package.swift                       SPM manifest — products + deps
Sources/
  HeidrunServer/                    @main executable; thin shim around HeidrunServerKit
  HeidrunServerKit/                 the actual server: actors, handlers, persistence, TLS, tracker
Tests/
  HeidrunServerKitTests/            Swift Testing suites + TestCerts/ resource bundle
heidrun-server.example.toml         annotated sample config (source of truth)
Dockerfile, docker-compose.yml      production container build
deploy/
  systemd/heidrun-server.service    Linux unit
  launchd/org.tastybytes.heidrun-server.plist  macOS LaunchDaemon
docs/OPERATIONS.md                  operator runbook
```

## Commands

Pure SwiftPM — **no Xcode project**. Use `swift` directly.

```bash
swift run HeidrunServer                                       # build + run locally
swift build                                                   # build only
swift test                                                    # Swift Testing — not XCTest
swift test --filter HeidrunServerKitTests.AccountStoreTests   # single suite
swift package resolve                                         # refresh heidrun-protocol pin

docker build -t heidrun-server .
docker compose up -d --build
```

## Architecture

### Top-level actor: `HeidrunServer`

`Sources/HeidrunServerKit/HeidrunServer.swift` is the lifecycle actor. `start()` binds the control listener on `port` and the HTXF transfer listener on `port + 1`, optionally a TLS-wrapped sibling pair on `tls_port` / `tls_port + 1`. It owns the shared stores (`AccountStore`, `FileVault`, `FileMetadataStore`, `NewsTree`, `UserRegistry`, `TransferRegistry`, `PrivateChatRegistry`, optional `TrackerAnnouncer`) and hands them to each new `ClientSession`. `stop()` drains sessions and closes listeners.

### Per-connection: `ClientSession`

One actor per accepted TCP socket. The NIO channel feeds raw bytes into an `AsyncStream<Data>` via `SessionIOHandler` (`ByteStream.swift`); the session reads packets in a `for await` loop, decodes them with `HeidrunCore` types, and dispatches by transaction ID. Handlers split by category across `ClientSession+*.swift` extensions:

- `+Admin.swift` — createLogin / deleteLogin / openLogin / modifyLogin
- `+Files.swift` — list, info, download, upload, delete, mkdir, rename, move, alias
- `+PlainNews.swift`, `+ThreadedNews.swift` — both news subsystems
- `+PrivateChats.swift`, `+PrivateMessages.swift` — 1-on-1 chat + DM routing
- `+Banner.swift` — transID 212 banner replies
- `+Misc.swift` — kick, user info, agreement

Replies are built with `PacketEncoder.swift` static builders (each returns `Data` ready to write).

### Persistence

- **`AccountStore`** (GRDB actor) — `accounts` table with PBKDF2-SHA256 hashed passwords (~210k rounds prod, tiny in tests).
- **`FileMetadataStore`** (GRDB actor, same SQLite file) — `file_metadata` table keyed by **path relative to `files_root`**, holding HFS type/creator + comments. Decoupling metadata from the file tree means the tree can live on a separate volume.
- **`FileVault`** (actor) — Foundation-backed file ops against `files_root`. No in-band versioning.
- **`NewsTree`** (actor) — plain news as `[String]`, threaded news as a `[BundleNode]` tree. Persists atomically as JSON to `news_state_path` (auto-derived to `<db_path>.news.json` if unset).

### Network surface

- **Control channel**: bare NIO `ServerBootstrap`; no custom codecs — `SessionIOHandler` just streams reads.
- **HTXF transfer side-channel** (`port + 1`): `TransferRegistry` issues 32-bit transferIDs that clients quote in their HTXF handshake; `ServerFolderUpload` / `ServerFolderDownload` drive the folder framing.
- **TLS**: optional, all-or-nothing. `TLSContextBuilder` builds the NIOSSL context from PEM cert chain + key. Half-configured deploys **fail fast** rather than silently revert to cleartext.
- **Tracker**: `TrackerAnnouncer` sends one mobius-compatible UDP packet to each configured tracker every 5 minutes; failures are logged + skipped.

### Idle-away supervisor

If `idle_away_threshold > 0`, a supervisor task walks the live `UserRegistry` every `idle_away_poll_interval` seconds and flips `UserStatusFlags.away` on sessions that haven't sent a packet in `idle_away_threshold` seconds, broadcasting `userChanged` so peers dim that row. Next inbound packet clears it.

## Testing pattern

Swift Testing (`#expect`, `#require`), **not XCTest**. Network-level suites typically spin up a `HeidrunServer` instance bound to `127.0.0.1:0` (kernel-assigned port) with an in-memory DB + tempdir files root, then drive it with raw `NWConnection` clients or `HeidrunCore` codecs. TLS suites consume PEMs from the `TestCerts/` resource bundle via `Bundle.module`. Password hashing in tests uses a tiny round count so suites stay fast.

## Code style

<important>
**Identifiers must be descriptive and at least 3 characters long.** This applies to local variables, properties, function parameters, closure parameters, case-binding names, and tuple element labels. Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) — clarity at the point of use wins over brevity.

- ❌ `let fm = FileManager.default` / `let s = session` / `case .failure(let e):` / `{ s in ... }`
- ✅ `let fileManager = FileManager.default` / `let clientSession = ...` / `case .failure(let error):` / `{ socket in ... }`

**Narrow exemptions** (the only short names that are allowed):
- Generic type parameters: `T`, `U`, `V`, `Element`, `Failure`.
- Anonymous closure shorthand: `$0`, `$1`.
- The Swift argument *label* `id:` — internal parameter name must still be ≥ 3 chars.
- Math/coordinate variables in tight scopes (`x`, `y`, `z`); loop counters `i`/`j` in 1–2 line numeric loops.

Apply this when writing new code and when touching existing code — rename short identifiers in any file you modify.
</important>

## Wire-protocol gotchas

Wire types live in `heidrun-protocol` — see that repo's [README](https://github.com/franckjej/heidrun-protocol#wire-protocol-notes) for the full list. The ones that bite server-side most often:

- **All multi-byte ints are big-endian.**
- **String encoding** defaults to `.macOSRoman`.
- **Login/password obfuscation** = XOR every byte with `0xFF`. Applied to login (105) and password (106) on auth + most account-admin transactions — **except `openLogin` (352) where login goes plain**.
- **Path encoding** (objIDs 202, 212, 325): `UInt16 componentCount` + per-component `(UInt16 0 pad, UInt8 length, name bytes)`.
- **Hotline timestamps** = seconds since `1904-01-01 00:00:00 UTC` (classic Mac epoch).

## Tag / version convention

Bare semver — `1.0.0-rcN` (not `v1.0.0-rcN`). Pin pre-release tags with `exact:`, never `from:` (SemVer pre-release identifiers compare lexically, so `from: "1.0.0-rc10"` quietly resolves back to `rc9`).
