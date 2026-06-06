<pre align="center">
   __         _     __               
  / /_  ___  (_)___/ /______  ______ 
 / __ \/ _ \/ / __  / ___/ / / / __ \
/ / / /  __/ / /_/ / /  / /_/ / / / /
\/ /_/\___/_/\__,_/_/   \__,_/_/ /_/ 
</pre>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.2-orange.svg" alt="Swift 6.2"></a>
  <img src="https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-blue.svg" alt="macOS | Linux">
  <a href="https://www.gnu.org/licenses/gpl-2.0.html"><img src="https://img.shields.io/badge/License-GPLv2-blue.svg" alt="License: GPL v2"></a>
</p>

# HeidrunServer

A Swift 6, pure-SwiftNIO Hotline-protocol server. Pairs with the [Heidrun](https://github.com/franckjej/heidrun) macOS client (or any classic Hotline 1.x client). Runs on macOS and Linux from the same source.

## Features

- Hotline 1.x protocol: chat, plain + threaded news, private messages + private chats, kick, broadcast
- Persistent accounts (SQLite via GRDB) with PBKDF2-SHA256 password hashing
- Admin transactions: `createLogin` / `deleteLogin` / `openLogin` / `modifyLogin`
- File system: list, info, download, upload, delete, create folder, rename, move, alias
- HTXF transfer side-channel (port + 1) with data-fork resume
- Optional TLS sibling listener pair (encrypts control + transfer end-to-end)
- Tracker UDP registration (Mobius-compatible, 5-min beacon)
- Server banner (transID 212) — JPEG / GIF / BMP / PICT / URL
- Per-file metadata (HFS type/creator + comments) persisted alongside accounts
- Idle-away supervisor — auto-flips the away flag after configurable inactivity
- Server-side chat commands — `/version`, `/who`, `/topic`, `/broadcast`, `/kick`, `/usershistory`, `/away`, `/me`, …
- Structured logging via swift-log, graceful shutdown on SIGINT / SIGTERM

## Quick start

### Docker

```bash
docker compose up -d --build
```

Defaults: control port `5500`, HTXF transfer `5501`, admin `admin` / `CHANGE_ME_BEFORE_FIRST_RUN` (see `docker-compose.yml` to set a real password before the first run).

### Local (development)

```bash
swift run HeidrunServer
```

Binds `127.0.0.1:5500` + `127.0.0.1:5501`. Default admin is `admin` / `admin` against a fresh database — **change it immediately for any real deployment**.

## Configuration

Two layered sources: **env vars > TOML file > built-in defaults.**

The annotated source of truth for the config surface is [`heidrun-server.example.toml`](heidrun-server.example.toml). The high-traffic env vars:

| Var | Default | What it does |
|---|---|---|
| `HEIDRUN_CONFIG` | _(unset)_ | Path to a TOML config file |
| `HEIDRUN_PORT` | `5500` | Control port. Transfer port is always `port + 1` |
| `HEIDRUN_SERVER_NAME` | `Heidrun` | Display name in the user list |
| `HEIDRUN_AGREEMENT` | _(unset)_ | Banner text pushed after login (transID 109) |
| `HEIDRUN_CHAT_SUBJECT` | _(empty)_ | Initial public chat topic |
| `HEIDRUN_DB_PATH` | _(in-memory)_ | SQLite file for accounts + file metadata |
| `HEIDRUN_USER_HISTORY` | `on` | `0`/`false`/`no`/`off` disables `/usershistory` recording (privacy kill-switch) |
| `HEIDRUN_FILES_ROOT` | _(tempdir)_ | Directory the file ops operate on |
| `HEIDRUN_NEWS_PATH` | _(in-memory)_ | JSON snapshot file for news state |
| `HEIDRUN_ADMIN_LOGIN` / `HEIDRUN_ADMIN_PASSWORD` | `admin` / `admin` | Bootstrap admin (only seeded on a fresh DB) |
| `HEIDRUN_TRACKERS` | _(empty)_ | Comma-separated `host[:port][:password]` list of trackers |
| `HEIDRUN_TLS_PORT` / `_CERTIFICATE` / `_PRIVATE_KEY` | _(unset)_ | Enables the TLS sibling pair on `tls_port` / `tls_port + 1` |
| `HEIDRUN_BANNER_PATH` / `HEIDRUN_BANNER_KIND` | _(unset)_ / `jpeg` | Image file delivered via `downloadBanner` (transID 212) |
| `HEIDRUN_LOG_LEVEL` | `info` | swift-log level: `trace` / `debug` / `info` / … / `critical` |

Operator depth (TLS / Let's Encrypt deploy hooks, ufw-docker, bootstrap admin permission upgrade, tracker debugging, full env reference) lives in [`docs/OPERATIONS.md`](docs/OPERATIONS.md).

## Slash commands

Users can issue server commands by typing them into the public chat input. Slash-prefixed lines are intercepted server-side; only the sender sees the response.

| Command | What it does |
|---|---|
| `/version` | Version, build id, Swift compiler, platform, ports, uptime, user count |
| `/uptime` | One-liner: `*** uptime: 4d 11h 23m` |
| `/who` / `/users` | Roster dump with nicknames + socket IDs |
| `/whoami` | Self-info: nickname, socket, login, IP, client version, TLS yes/no, admin yes/no, away yes/no, raw privilege bitmask |
| `/away` | Toggle the away flag; broadcasts `userChanged` |
| `/me <action>` | IRC-style action chat |
| `/broadcast <msg>` | Server-wide popup (transID 355). Admin-only (`.canBroadcast`) |
| `/topic [text]` | Read or set the public chat topic. Set is admin-only |
| `/kick <socketID>` | Disconnect a target. Admin-only (`.disconnectUsers`) |
| `/usershistory [hours]` / `/history` | User join/leave history for the last 1–24h (default 1h). Admin-only (`.disconnectUsers`). Disable with `HEIDRUN_USER_HISTORY=0` |
| `/invisible` / `/visible` | Hide / re-show in peer rosters. Admin-only |
| `/help` | List every command with one-line description |

Single `/` prefix only — `//foo` and a bare `/` fall through as normal chat. Case-insensitive on the command head.

## Tested deployment images

| Image | Status |
|---|---|
| `swift:6.2-jammy` (Ubuntu 22.04) | Builds + runs |
| `swift:6.2-noble` (Ubuntu 24.04) | Builds + runs |
| `swift:6.0-jammy` | **Too old** — swift-log 1.12+ requires Swift 6.2 |

## Architecture

`HeidrunServer` (lifecycle actor) binds the listener pair and owns the shared stores. Each accepted connection becomes a `ClientSession` actor that decodes Hotline packets via `HeidrunCore` and dispatches them across `ClientSession+*.swift` extensions (Admin, Files, PlainNews, ThreadedNews, PrivateChats, PrivateMessages, Banner, Misc). Replies are built with static `PacketEncoder` builders.

Wire types and codecs live in the shared SPM package [`franckjej/heidrun-protocol`](https://github.com/franckjej/heidrun-protocol). Edits to the wire format happen there, not here.

For protocol details (encoding quirks, transaction IDs, HTXF framing, 1904-epoch timestamps) see [`AGENTS.md`](AGENTS.md) or the heidrun-protocol README.

## License

GPL-2.0. Full text in [`LICENSE`](LICENSE).

### Dual licensing

Copyright © Daubit & Francke GmbH. The copyright holder reserves all rights to license this code under other terms — commercial, proprietary, BSD/MIT-style, or any other arrangement — for its own products and for third parties on request. The GPL-2.0 grant above governs public/community use; it does not bind the copyright holder's re-use of the same code under different terms.

For a non-GPL licence: `jens.francke@daubit-francke.de`.

### Third-party

Built on Apple's Apache 2.0 Swift packages: [swift-nio](https://github.com/apple/swift-nio), [swift-nio-ssl](https://github.com/apple/swift-nio-ssl), [swift-log](https://github.com/apple/swift-log), [swift-crypto](https://github.com/apple/swift-crypto). Persistence via [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT). TOML parsing via [TOMLKit](https://github.com/LebJe/TOMLKit) (MIT).

## Heritage

Heidrun is a Swift 6 reimplementation of the 2002 Hotline Mac client by **Göran Granström**, whose original plug-in modules were GPL-2.0. This server is a new ground-up implementation but shares the protocol heritage and the same licensing posture.
