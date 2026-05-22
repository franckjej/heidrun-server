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
| `HEIDRUN_TRACKERS` | _(empty)_ | Comma-separated `host[:port][:password]` list of trackers to register with (mobius-compatible). Empty disables tracker registration |
| `HEIDRUN_TRACKER_DESCRIPTION` | _(server name)_ | Free-text description shown in tracker listings |
| `HEIDRUN_TLS_PORT` | _(unset)_ | Sibling TLS control port. Transfer TLS is `tls_port + 1`. Unset / 0 disables TLS entirely |
| `HEIDRUN_TLS_CERTIFICATE` | _(unset)_ | Path to PEM-encoded TLS certificate chain |
| `HEIDRUN_TLS_PRIVATE_KEY` | _(unset)_ | Path to PEM-encoded TLS private key |
| `HEIDRUN_BANNER_PATH` | _(unset)_ | Image file the server delivers via the 212 `downloadBanner` transaction. Loaded into memory at startup; unset / empty disables the banner |
| `HEIDRUN_BANNER_KIND` | `jpeg` | Format hint sent in the 212 reply (field 152). One of `jpeg`, `gif`, `bmp`, `pict`, `url` |
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

When TLS is enabled (`tls_port` / `HEIDRUN_TLS_PORT`), a second pair
binds on `tls_port` and `tls_port + 1`. The recommended convention is
5502 + 5503 so the cleartext and TLS ports never share a host:port.

### TLS

The server supports an optional TLS sibling listener pair on top of
the cleartext one. When configured, both the Hotline control channel
and HTXF file transfers are encrypted end-to-end; sniffing the wire
reveals no readable Hotline frames or file bytes. The cleartext pair
stays bound for legacy clients, so enabling TLS is purely additive.

**1. Get a certificate.** Production deploys use a publicly-issued
TLS cert (Let's Encrypt is the default choice). Since HeidrunServer
doesn't speak HTTP, ACME HTTP-01 isn't an option — use **DNS-01**:

```bash
sudo certbot certonly \
  --manual --preferred-challenges dns \
  -d hotline.example.com
```

Certbot stores the issued cert under
`/etc/letsencrypt/live/<domain>/` (or wherever your certbot working
directory points). The two files Heidrun needs are `fullchain.pem`
(server cert + intermediates) and `privkey.pem`.

**2. Mount the cert pair into the container.** Don't bind-mount
certbot's working directory directly — Certbot writes `live/` and
`archive/` as `0700 root:root`, and the unprivileged `heidrun` user
inside the container can't traverse into them. The first symptom is
a startup error like
`error=missingCertificate(path: ".../fullchain.pem")` — misleading;
the file is there, the process just can't `stat` it past the parent
directory's perms.

The clean fix is a dedicated heidrun-owned directory on the host that
mirrors the two files. One-time setup:

```bash
HEIDRUN_UID=$(docker exec heidrun-server id -u heidrun)
HEIDRUN_GID=$(docker exec heidrun-server id -g heidrun)
sudo mkdir -p /etc/heidrun-server/tls
sudo cp -L /etc/letsencrypt/live/hotline.example.com/fullchain.pem /etc/heidrun-server/tls/
sudo cp -L /etc/letsencrypt/live/hotline.example.com/privkey.pem   /etc/heidrun-server/tls/
sudo chown -R "$HEIDRUN_UID:$HEIDRUN_GID" /etc/heidrun-server/tls
sudo chmod 644 /etc/heidrun-server/tls/fullchain.pem
sudo chmod 640 /etc/heidrun-server/tls/privkey.pem
```

The `-L` follows the symlinks under `live/` and copies the real
bytes — if you skip it, the symlinks dangle inside the container.

Then in `docker-compose.yml`, uncomment the TLS bind mount and the
three TLS env vars (the compose file's commented stubs match this
layout verbatim):

```yaml
volumes:
  - /etc/heidrun-server/tls:/etc/heidrun-server/tls:ro
ports:
  - "5502:5502"
  - "5503:5503"
environment:
  HEIDRUN_TLS_PORT: "5502"
  HEIDRUN_TLS_CERTIFICATE: "/etc/heidrun-server/tls/fullchain.pem"
  HEIDRUN_TLS_PRIVATE_KEY: "/etc/heidrun-server/tls/privkey.pem"
```

If you're using `ufw-docker`, open the two new ports the same way as
5500/5501 — plain `ufw allow` doesn't cover Docker-DNAT'd ports.

**3. Wire up renewal.** Certbot writes a new cert into `live/<domain>/`
on every successful `certbot renew`, but the heidrun process loads
the TLS context once at startup and won't pick up the new file until
it restarts. Add a deploy hook so a fresh cert auto-propagates and
the process cycles. The first half (copy + chown + perms) is
identical across deploy targets; only the restart command differs.

#### Docker Compose deploy

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/heidrun.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LIVE_DIR="/etc/letsencrypt/live/hotline.example.com"
DEST="/etc/heidrun-server/tls"
HEIDRUN_UID=$(docker exec heidrun-server id -u heidrun)
HEIDRUN_GID=$(docker exec heidrun-server id -g heidrun)
cp -L "$LIVE_DIR/fullchain.pem" "$DEST/fullchain.pem"
cp -L "$LIVE_DIR/privkey.pem"   "$DEST/privkey.pem"
chown "$HEIDRUN_UID:$HEIDRUN_GID" "$DEST"/{fullchain,privkey}.pem
chmod 644 "$DEST/fullchain.pem"
chmod 640 "$DEST/privkey.pem"
docker compose -f /path/to/heidrun/docker-compose.yml restart heidrun
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/heidrun.sh
```

#### systemd deploy (Linux)

The unit at `deploy/systemd/heidrun-server.service` already grants
the heidrun service user read access to `/etc/heidrun-server` via
`ReadOnlyPaths=`, so the same `/etc/heidrun-server/tls/` layout
works without changes. The deploy hook only needs to know the
service user's `uid:gid` (which is whatever `useradd --system
heidrun` picked at install time):

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/heidrun.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LIVE_DIR="/etc/letsencrypt/live/hotline.example.com"
DEST="/etc/heidrun-server/tls"
cp -L "$LIVE_DIR/fullchain.pem" "$DEST/fullchain.pem"
cp -L "$LIVE_DIR/privkey.pem"   "$DEST/privkey.pem"
chown heidrun:heidrun "$DEST"/{fullchain,privkey}.pem
chmod 644 "$DEST/fullchain.pem"
chmod 640 "$DEST/privkey.pem"
systemctl restart heidrun-server
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/heidrun.sh
```

#### launchd deploy (macOS)

`launchctl kickstart -k` stops the daemon and immediately re-launches
it (the `-k` is the "kill first" flag). The user/group names match
whatever's set in the `.plist`:

```bash
sudo tee /usr/local/etc/heidrun-server/renew-tls.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LIVE_DIR="/etc/letsencrypt/live/hotline.example.com"
DEST="/usr/local/etc/heidrun-server/tls"
cp -L "$LIVE_DIR/fullchain.pem" "$DEST/fullchain.pem"
cp -L "$LIVE_DIR/privkey.pem"   "$DEST/privkey.pem"
chown _heidrun:_heidrun "$DEST"/{fullchain,privkey}.pem
chmod 644 "$DEST/fullchain.pem"
chmod 640 "$DEST/privkey.pem"
launchctl kickstart -k system/org.tastybytes.heidrun-server
EOF
sudo chmod +x /usr/local/etc/heidrun-server/renew-tls.sh
sudo ln -sf /usr/local/etc/heidrun-server/renew-tls.sh \
            /etc/letsencrypt/renewal-hooks/deploy/heidrun.sh
```

(macOS doesn't have a `heidrun` system user out of the box — pick a
service account name when you install the LaunchDaemon and use it
consistently across the `.plist` and the hook script.)

#### Notes that apply to all three

Certbot runs every executable in `/etc/letsencrypt/renewal-hooks/deploy/`
once after a successful renewal — exit non-zero from the hook and
Certbot fails the renewal, so `set -euo pipefail` is doing real
work. Test the hook manually after first install with
`sudo /etc/letsencrypt/renewal-hooks/deploy/heidrun.sh`.

The restart only cycles the TLS listener pair; the cleartext pair
on 5500/5501 is dropped along with it, so any in-flight cleartext
sessions also disconnect. Consider scheduling renewal off-peak if
that matters.

**Half-configured deploys fail fast.** Setting `tls_port` without
both a cert path and a key path throws at startup with a typed
`TLSContextError.loadFailed(reason: …)` instead of silently falling
back to cleartext — so an operator who thought they had TLS can't
end up with an unencrypted listener by accident.

### State directories

| Path | What's there |
|---|---|
| `db_path` | One SQLite file. Holds **accounts** + per-file **metadata** (comments + HFS type/creator). Backed up = backed up accounts + metadata |
| `files_root` | The file tree the server serves. Plain on-disk files; modern filesystems handle it. File comments + HFS type/creator now persist via the SQLite DB above (path-keyed); files dropped on the tree out-of-band have no row and fall back to `.file/.unknown` defaults |

### Resource forks

Resource forks are intentionally dropped throughout. Files round-trip
as data-fork-only. Modern macOS doesn't use resource forks, but if you
need them for an archival workflow, both ends need work.

### Persistent metadata

The SQLite database carries accounts, their hashes, and per-file
metadata (HFS type/creator + comments). Metadata is keyed by the
file's relative path from `files_root` so the same DB works whether
the files tree lives in the named volume or a bind-mounted RAID.
Folder renames + moves rewrite descendant rows in one transaction;
file deletes drop the row; uploads persist the FILP envelope's
type/creator. Custom per-file icons are not yet persisted — that's
the remaining v1.5 item in this area.

### Server banner

The Hotline `downloadBanner` transaction (transID 212) lets the
server push a logo / splash image to connected clients. Heidrun
clients display it as a strip at the top of the host workspace
sidebar; other modern clients (mobius, mierau's hotline) show it on
the connection-info screen.

**1. Place the image somewhere readable by the heidrun user.** Same
constraint as the TLS cert — the unprivileged process inside the
container can't reach files under `0700 root:root` parents. The
cleanest path on a Docker deploy is `/etc/heidrun-server/banner.jpg`,
mounted alongside the TLS cert directory:

```bash
HEIDRUN_UID=$(docker exec heidrun-server id -u heidrun)
HEIDRUN_GID=$(docker exec heidrun-server id -g heidrun)
sudo install -d -o "$HEIDRUN_UID" -g "$HEIDRUN_GID" /etc/heidrun-server
sudo install -m 0644 -o "$HEIDRUN_UID" -g "$HEIDRUN_GID" \
    /path/to/banner.jpg /etc/heidrun-server/banner.jpg
```

**2. Configure compose** (uncomment the block already in
`docker-compose.yml`):

```yaml
environment:
  HEIDRUN_BANNER_PATH: "/etc/heidrun-server/banner.jpg"
  HEIDRUN_BANNER_KIND: "jpeg"
```

`HEIDRUN_BANNER_KIND` is one of `jpeg` / `gif` / `bmp` / `pict` /
`url`. JPEG is the realistic default for new deployments — every
modern client decodes it via system image APIs (`NSImage`,
`UIImage`, etc.). `url` mode treats the file's contents as a UTF-8
link the client fetches itself (Heidrun's macOS client skips URL-
mode banners in v1).

**3. Restart the container.** Bytes are loaded once at startup and
cached in memory — updating the image needs a `docker compose
restart heidrun` (same workflow as the TLS cert).

**Operational notes:**

- Recommended size: ~468×60 pixels, the de-facto standard from the
  classic Hotline era. Heidrun renders the bytes at native aspect
  with an 80pt max height.
- A missing / unreadable file logs a warning at startup and disables
  the banner — 212 requests then reply with an error, which the
  client maps to "no banner" rather than treating as a failure. A
  half-configured deploy can't accidentally serve a stale or empty
  banner.
- The bytes ride the same HTXF side-channel as file downloads (port
  + 1, or TLS sibling + 1 when TLS is on), with a banner-flavoured
  preamble (`type=2`) so the dispatcher can distinguish it from a
  regular file stream.

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

- Persistent file icons (HFS type/creator + comments now persist; icon
  blobs are still deferred)
- Admin CLI tool (`heidrun-server-admin`)
- launchd / systemd integration tests
- Self-signed-cert opt-in on the client (TLS today requires a
  publicly-trusted CA chain on the server)
