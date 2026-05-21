# HeidrunServer

Swift-on-server Hotline protocol server. Pairs with the Heidrun macOS
client (or any classic Hotline 1.x client). Runs on macOS and Linux
from the same source.

## Features (v1)

- Hotline protocol: chat, plain + threaded news, private messages, kick
- Persistent accounts (SQLite via GRDB) with PBKDF2-SHA256 password
  hashing at rest
- Admin transactions: createLogin / deleteLogin / openLogin / modifyLogin
- File system: list, info, download, upload, delete, create folder,
  rename, move, alias
- HTXF transfer side-channel (port + 1) with data-fork resume
- Graceful shutdown on SIGINT / SIGTERM
- Structured logging via swift-log
- TOML config file or env-var-only configuration

## Quick start

### macOS (development)

```bash
swift run --package-path Packages/HeidrunServer HeidrunServer
```

The server listens on `127.0.0.1:5500` (control) and `127.0.0.1:5501`
(HTXF transfer). Default admin credentials are `admin` / `admin` on a
fresh database — **change them immediately for any real deployment**.

### Docker

```bash
docker build -t heidrun-server -f Packages/HeidrunServer/Dockerfile .
docker run -d --name heidrun \
  -p 5500:5500 -p 5501:5501 \
  -v heidrun-data:/var/lib/heidrun \
  -e HEIDRUN_ADMIN_PASSWORD=$(openssl rand -base64 24) \
  heidrun-server
```

Or with `docker-compose`:

```bash
docker compose -f Packages/HeidrunServer/docker-compose.yml up -d
```

### Linux (systemd)

See `deploy/systemd/heidrun-server.service`. Install with:

```bash
install -d /var/lib/heidrun/{files} /etc/heidrun-server
install -m 0755 ./HeidrunServer /usr/local/bin/heidrun-server
install -m 0644 Packages/HeidrunServer/heidrun-server.example.toml \
                /etc/heidrun-server/config.toml
$EDITOR /etc/heidrun-server/config.toml           # set a real admin password
install -m 0644 Packages/HeidrunServer/deploy/systemd/heidrun-server.service \
                /etc/systemd/system/
useradd --system --home-dir /var/lib/heidrun --shell /usr/sbin/nologin heidrun
chown -R heidrun:heidrun /var/lib/heidrun
systemctl daemon-reload
systemctl enable --now heidrun-server
```

### macOS (LaunchDaemon)

See `deploy/launchd/org.tastybytes.heidrun-server.plist`. Install with:

```bash
sudo install -d /usr/local/var/heidrun/files /usr/local/etc/heidrun-server
sudo install -m 0755 ./HeidrunServer /usr/local/bin/heidrun-server
sudo install -m 0644 Packages/HeidrunServer/heidrun-server.example.toml \
                     /usr/local/etc/heidrun-server/config.toml
sudo $EDITOR /usr/local/etc/heidrun-server/config.toml
sudo install -m 0644 \
  Packages/HeidrunServer/deploy/launchd/org.tastybytes.heidrun-server.plist \
  /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/org.tastybytes.heidrun-server.plist
```

## Building

Requires **Swift 6.2** or newer (Linux deployment) or **Xcode 16.x+**
(macOS development). Swift's released Linux toolchain is available as
the official `swift:6.2-jammy` (Ubuntu 22.04) and `swift:6.2-noble`
(Ubuntu 24.04) Docker images.

```bash
# macOS / Linux
swift build --package-path Packages/HeidrunServer --configuration release

# Resulting binary
ls Packages/HeidrunServer/.build/release/HeidrunServer
```

## Configuration

Two layered sources: **env vars override the TOML file, which overrides
built-in defaults.**

### Environment variables

| Var | Default | What it does |
|---|---|---|
| `HEIDRUN_CONFIG` | _(unset)_ | Path to a TOML config file |
| `HEIDRUN_PORT` | `5500` | Control port. Transfer port is always `port + 1` |
| `HEIDRUN_SERVER_NAME` | `Heidrun` | Display name in the user list |
| `HEIDRUN_AGREEMENT` | _(unset)_ | Banner text pushed after login (transID 109) |
| `HEIDRUN_DB_PATH` | _(in-memory)_ | SQLite file for accounts |
| `HEIDRUN_FILES_ROOT` | _(tempdir)_ | Directory the file ops operate on |
| `HEIDRUN_ADMIN_LOGIN` | `admin` | Login for the bootstrap admin (only seeded on a fresh DB) |
| `HEIDRUN_ADMIN_PASSWORD` | `admin` | Password for the bootstrap admin |
| `HEIDRUN_ADMIN_NICKNAME` | `Admin` | Nickname for the bootstrap admin |
| `HEIDRUN_LOG_LEVEL` | `info` | swift-log level: `trace` / `debug` / `info` / `notice` / `warning` / `error` / `critical` |

### TOML config file

See `heidrun-server.example.toml`. Every key is optional. Example:

```toml
port = 5500
server_name = "Heidrun"
log_level = "info"
db_path = "/var/lib/heidrun/heidrun.sqlite"
files_root = "/var/lib/heidrun/files"

[bootstrap_admin]
login = "admin"
password = "rotate-me-immediately"
```

## Operational notes

### Default admin credentials

On the **very first** startup against an empty database, the server
seeds an account with `HEIDRUN_ADMIN_LOGIN` / `HEIDRUN_ADMIN_PASSWORD`
(default `admin` / `admin`). After the first startup these env vars are
**ignored** — the account exists. To change the password later, use
the `modifyLogin` (transID 353) admin transaction from any logged-in
client with the `modifyAccounts` privilege.

### Ports

The server binds two adjacent TCP ports: `port` (Hotline control) and
`port + 1` (HTXF file transfer side-channel). Both must be reachable
from clients. Most firewalls just open both — they're conventionally
5500 + 5501.

### State directories

| Path | What's there |
|---|---|
| `db_path` | One SQLite file. Backed up = backed up accounts |
| `files_root` | The file tree the server serves. Plain on-disk files; modern filesystems handle it. Comments are an in-memory sidecar — not yet persisted (see v1.5 notes) |

### Resource forks

Resource forks are intentionally dropped throughout. Files round-trip
as data-fork-only. Modern macOS doesn't use resource forks, but if you
need them for an archival workflow, both ends need work.

### Persistent metadata

In v1 the SQLite database carries accounts + their hashes. File
metadata (HFS type/creator, comments, icons) is not yet persisted —
comments live in memory and wipe on restart. This is on the v1.5 list.

## Tested deployment images

| Image | Status |
|---|---|
| `swift:6.2-jammy` (Ubuntu 22.04) | Builds + runs |
| `swift:6.2-noble` (Ubuntu 24.04) | Builds + runs |
| `swift:6.0-jammy` | **Too old** — swift-log 1.12+ requires Swift 6.2 |

## See also

- `heidrun-server.example.toml` — annotated sample config
- `Dockerfile` — production multi-stage Docker build
- `docker-compose.yml` — single-command Docker deploy
- `deploy/launchd/` — macOS LaunchDaemon plist
- `deploy/systemd/` — Linux systemd unit

## Out of scope (v1)

The following are deferred to v1.5:

- TLS-wrapped variant on a sibling port (currently cleartext only)
- UDP tracker beacon registration
- Persistent file metadata (HFS type/creator, comments, icons in
  SQLite)
- Folder bulk transfers (transID 210 / 213) — single-file workflows
  are fully supported; folder up/down via the client UI will fail
- Server banner image
- Admin CLI tool (`heidrun-server-admin`)
- launchd / systemd integration tests
