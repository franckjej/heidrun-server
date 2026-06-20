# HeidrunServer — Operations Guide

Operator-facing depth that doesn't belong in the README. Covers installation, TLS lifecycle, tracker registration, bootstrap admin upgrades, and the server banner.

## Installation

### Linux (systemd)

```bash
install -d /var/lib/heidrun/{files} /etc/heidrun-server
install -m 0755 ./HeidrunServer /usr/local/bin/heidrun-server
install -m 0644 heidrun-server.example.toml \
                /etc/heidrun-server/config.toml
$EDITOR /etc/heidrun-server/config.toml           # set a real admin password
install -m 0644 deploy/systemd/heidrun-server.service \
                /etc/systemd/system/
useradd --system --home-dir /var/lib/heidrun --shell /usr/sbin/nologin heidrun
chown -R heidrun:heidrun /var/lib/heidrun
systemctl daemon-reload
systemctl enable --now heidrun-server
```

### macOS (LaunchDaemon)

```bash
sudo install -d /usr/local/var/heidrun/files /usr/local/etc/heidrun-server
sudo install -m 0755 ./HeidrunServer /usr/local/bin/heidrun-server
sudo install -m 0644 heidrun-server.example.toml \
                     /usr/local/etc/heidrun-server/config.toml
sudo $EDITOR /usr/local/etc/heidrun-server/config.toml
sudo install -m 0644 \
  deploy/launchd/org.tastybytes.heidrun-server.plist \
  /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/org.tastybytes.heidrun-server.plist
```

## Building from source

Requires **Swift 6.2** or newer (Linux) or **Xcode 16.x+** (macOS).

```bash
swift build --configuration release
ls .build/release/HeidrunServer
```

### Build identifier

The running server surfaces a semver + short build identifier via `/version`. The Docker image auto-stamps via the `git-info` Dockerfile stage — `git rev-parse --short HEAD` and `date -u +%Y-%m-%d` are written into `/usr/local/share/heidrun/{build-id,build-date}` inside the image. `HeidrunServerInfo` reads those at runtime via `HEIDRUN_BUILD_INFO_DIR`.

Resolution order at runtime (first non-empty wins):

1. `HEIDRUN_BUILD` / `HEIDRUN_BUILD_DATE` env vars — CI / explicit override
2. Files under `HEIDRUN_BUILD_INFO_DIR` (the Dockerfile path)
3. `"dev"` and an empty date for `swift run` / unstamped releases

A new commit invalidates only the small `git-info` stage; the multi-minute swift package resolve and the swift build stage stay cached.

## Default admin credentials

On the very first startup against an empty database, the server seeds an account with `HEIDRUN_ADMIN_LOGIN` / `HEIDRUN_ADMIN_PASSWORD` (default `admin` / `admin`). After that, the env vars are **ignored** — the account exists. Use `modifyLogin` (transID 353) from a logged-in admin to change the password later.

### Upgrading admin permissions on an older DB

Builds since May 2026 seed the bootstrap admin with **every defined privilege bit** (`UserPrivileges.all`). Earlier builds only seeded five bits — enough to administer accounts but missing upload, download, file ops, news, and the `disconnectUsers` flag that drives the red admin-name colour in clients. If your deployment predates that change, the existing admin row stays untouched on restart (the seed only runs against an empty accounts table). Three ways to fix:

**1. From a connected admin client** (preferred). The current admin holds `modifyAccounts`, so grant the missing bits via `modifyLogin` and re-login.

**2. Direct SQL** against the SQLite DB (server stopped):

```bash
docker compose stop heidrun
sqlite3 /var/lib/docker/volumes/heidrun-server_heidrun-data/_data/heidrun.sqlite \
  "UPDATE accounts SET permissions = 2199022731263 WHERE login = 'admin';"
docker compose start heidrun
```

`2199022731263` is `0x1FFFFF7FFFF` — `UserPrivileges.all.rawValue` (bits 0–18, 20–40; bit 19 is unused). If upstream adds bits, read the exact value from the `bootstrap admin seeded permissions=0x…` log line of a fresh-DB startup.

**3. One-shot env-var hook** — set `HEIDRUN_RESET_ADMIN_PERMISSIONS=1` (or `reset_admin_permissions = true` in TOML) to rewrite the bootstrap admin row's permissions to `UserPrivileges.all` on the next startup. Logs at INFO. Flip on, deploy once, flip back off:

```bash
HEIDRUN_RESET_ADMIN_PERMISSIONS=1 docker compose up -d
# confirm the log line, then:
unset HEIDRUN_RESET_ADMIN_PERMISSIONS
docker compose up -d
```

## Guest account

Anonymous connections (empty login) attach to a real `guest` row in the accounts DB. The server ensures the row exists at every startup. To tune:

- **Modify guest privileges the same way as any other account** — `modifyLogin` (transID 353) from an admin client. Persists across restarts.
- Default seed: chat (read + send), private chat + DMs, news read, file + folder downloads, `showInList`. Deliberately **without** `.getUserInfo` so guests can't fetch other users' IPs.
- To lock anonymous access out entirely, `deleteLogin` the `guest` row. Empty-login connections then attach with `nil` privileges (pre-guest behaviour); every gated handler rejects them.

Seed log:

```
guest account seeded   login=guest permissions=0x18000103e04
```

## Ports

| Cleartext | TLS (when configured) |
|---|---|
| `port` (default 5500) — Hotline control | `tls_port` (recommended 5502) — Hotline control (TLS) |
| `port + 1` (default 5501) — HTXF file transfer | `tls_port + 1` (recommended 5503) — HTXF (TLS) |

All bound ports must be reachable from clients. The TLS sibling pair is purely additive; the cleartext pair stays bound for legacy clients.

## TLS

### Self-signed (no public CA)

NIOSSL doesn't validate its own cert, so a self-signed pair works with no extra server config:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout key.pem -out cert.pem \
  -subj "/CN=hotline.example.com"
```

Point `HEIDRUN_TLS_CERTIFICATE` / `HEIDRUN_TLS_PRIVATE_KEY` at the two files and set `HEIDRUN_TLS_PORT`. On first connect the Heidrun client shows the cert's SHA-256 fingerprint and asks you to trust it (trust-on-first-use), then pins it for that bookmark — later connects are silent. Regenerated certs trigger a fingerprint-changed warning.

### Let's Encrypt (publicly-issued)

HeidrunServer doesn't speak HTTP, so ACME HTTP-01 isn't an option — use **DNS-01**:

```bash
sudo certbot certonly \
  --manual --preferred-challenges dns \
  -d hotline.example.com
```

Certbot stores `fullchain.pem` and `privkey.pem` under `/etc/letsencrypt/live/<domain>/`.

**Mount the cert pair into the container.** Don't bind-mount certbot's working directory directly — Certbot writes `live/` and `archive/` as `0700 root:root`, and the unprivileged `heidrun` user inside the container can't traverse into them. The first symptom is a startup error like `error=missingCertificate(path: ".../fullchain.pem")` — misleading; the file is there, the process just can't `stat` it past the parent directory's perms.

Use a dedicated heidrun-owned directory on the host that mirrors the two files:

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

`-L` follows the symlinks under `live/` and copies the real bytes — without it, the symlinks dangle inside the container.

Then in `docker-compose.yml`, uncomment the TLS bind mount and the three TLS env vars (the compose file's commented stubs match this layout verbatim).

### Cert renewal hooks

Certbot renews into `live/<domain>/` but heidrun loads the TLS context once at startup. Wire a deploy hook so a fresh cert propagates and the process restarts. The copy + chown + perms half is identical across deploy targets; only the restart command differs.

**Docker Compose:**

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

**systemd (Linux):** the unit at `deploy/systemd/heidrun-server.service` grants the service user read access to `/etc/heidrun-server` via `ReadOnlyPaths=`, so the same `/etc/heidrun-server/tls/` layout works:

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

**launchd (macOS):** `launchctl kickstart -k` stops the daemon and immediately re-launches it (`-k` = kill first). The user/group names match whatever's set in the `.plist`. macOS doesn't have a `heidrun` system user out of the box — pick a service account name when you install the LaunchDaemon and use it consistently:

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

**Notes that apply to all three:** Certbot runs every executable in `/etc/letsencrypt/renewal-hooks/deploy/` once after a successful renewal — exit non-zero and Certbot fails the renewal, so `set -euo pipefail` is doing real work. Test manually after first install: `sudo /etc/letsencrypt/renewal-hooks/deploy/heidrun.sh`. The restart cycles the TLS listener pair; the cleartext pair on 5500/5501 also drops, so any in-flight cleartext sessions disconnect. Consider scheduling renewal off-peak.

### Fail-fast on half-configured deploys

Setting `tls_port` without both a cert path and a key path throws at startup with a typed `TLSContextError.loadFailed(reason: …)` instead of silently falling back to cleartext — an operator who thought they had TLS can't end up with an unencrypted listener by accident.

## Tracker registration

When `HEIDRUN_TRACKERS` (or `trackers = […]` in TOML) is set, the server sends one UDP datagram to each tracker every 5 minutes. The packet advertises the server's name, description, control port, live user count, and an optional password.

**The two-port gotcha:** Hotline trackers use **UDP 5499** for server registration and **TCP 5498** for client list fetches. Registering on 5498 by mistake means nothing receives the datagram and the server silently never appears in any listing — so HeidrunServer entries default to port 5499.

### Verifying the announcer

The boot log carries three INFO lines:

```
tracker configuration loaded   count=N hosts=...
tracker announcer starting     trackers=N
tracker registered             tracker=hltracker.com:5499 bytes=NN
```

If you see `tracker announcer disabled (no trackers configured)`, `HEIDRUN_TRACKERS` didn't reach the process. Env vars in `docker-compose.yml` only take effect after `docker compose up -d --build`. Check inside the container:

```bash
docker exec heidrun-server env | grep TRACK
```

### ufw-docker + outbound UDP

`bytes=NN` in the log only confirms the kernel accepted the write — not that the packet left the host. If registrations succeed from the server's perspective but the server doesn't appear in tracker listings, capture on the host:

```bash
sudo tcpdump -i any -n udp port 5499
# wait up to 5 min for the next cycle (or restart to force an immediate send).
```

A successful send shows one outbound UDP packet from the host's public IP to the tracker. No packet on the wire = ufw / ufw-docker / the docker bridge is dropping it; allow outbound UDP to port 5499 from the docker network's CIDR.

### Server reachability

Trackers hand `advertisedPort` (your `HEIDRUN_PORT`, default 5500) back to browsing clients, who dial `your-public-IP:5500`. If 5500 / 5501 aren't reachable from the public internet, clients see the listing but fail to connect — symptoms look identical to "we don't get listed" from a user's perspective. Open the cleartext pair (and 5502/5503 if TLS is on) inbound; `ufw-docker` is required for Docker-DNAT'd ports.

## State directories

| Path | Contents |
|---|---|
| `db_path` | One SQLite file: accounts + per-file metadata (HFS type/creator + comments) |
| `files_root` | The file tree the server serves. Plain on-disk files |
| `news_state_path` | JSON snapshot of news state (plain feed + threaded tree); auto-derives to `<db>.news.json` if unset |

Metadata is keyed by **path relative to `files_root`** — the same DB works whether the files tree lives in the named volume or a bind-mounted RAID. Folder renames + moves rewrite descendant rows in one transaction; deletes drop the row; uploads persist the FILP envelope's HFS type/creator.

Custom per-file icons (icon blobs) are not yet persisted — deferred to v1.5.

### Resource forks

Intentionally dropped throughout. Files round-trip as data-fork-only. Modern macOS doesn't use resource forks; if you need them for an archival workflow, both ends need work.

## Server banner

The Hotline `downloadBanner` transaction (transID 212) lets the server push a logo / splash image to connected clients. Heidrun clients display it as a strip at the top of the host workspace sidebar; mobius and mierau's hotline show it on the connection-info screen.

**1. Place the image where the heidrun user can read it.** Same constraint as the TLS cert — the unprivileged process inside the container can't reach files under `0700 root:root` parents.

```bash
HEIDRUN_UID=$(docker exec heidrun-server id -u heidrun)
HEIDRUN_GID=$(docker exec heidrun-server id -g heidrun)
sudo install -d -o "$HEIDRUN_UID" -g "$HEIDRUN_GID" /etc/heidrun-server
sudo install -m 0644 -o "$HEIDRUN_UID" -g "$HEIDRUN_GID" \
    /path/to/banner.jpg /etc/heidrun-server/banner.jpg
```

**2. Configure compose** (uncomment the block already in `docker-compose.yml`):

```yaml
environment:
  HEIDRUN_BANNER_PATH: "/etc/heidrun-server/banner.jpg"
  HEIDRUN_BANNER_KIND: "jpeg"
```

`HEIDRUN_BANNER_KIND` is one of `jpeg` / `gif` / `bmp` / `pict` / `url`. JPEG is the realistic default — every modern client decodes it via system image APIs. `url` mode treats the file's contents as a UTF-8 link the client fetches itself (Heidrun's macOS client skips URL-mode banners in v1).

**3. Restart the container.** Bytes are loaded once at startup and cached in memory — updating the image needs a `docker compose restart heidrun`.

### Banner notes

- Recommended size: **~468×60 pixels**, the de-facto standard from the classic Hotline era. Heidrun renders the bytes at native aspect with an 80pt max height.
- A missing / unreadable file logs a warning at startup and disables the banner — 212 requests then reply with an error, which the client maps to "no banner" rather than treating as a failure. A half-configured deploy can't accidentally serve a stale or empty banner.
- The bytes ride the same HTXF side-channel as file downloads (port + 1, or TLS sibling + 1 when TLS is on), with a banner-flavoured preamble (`type=2`) so the dispatcher can distinguish it from a regular file stream.

## Audit log

The server records significant events to a dedicated SQLite file
(`audit_db_path`, default a `<db_path>.audit.sqlite` sibling), separate
from the accounts DB so it can be rotated or erased on its own.

**What's recorded:** presence (`join` / `leave`), file transfers
(`upload` / `download`, logged at request time with filename and size),
auth (`login_ok` / `login_fail`, the latter carrying the attempted
account), and admin actions (`account_create` / `account_modify` /
`account_delete`, `kick`, `broadcast`, `topic`).

**Retention:** `audit_retention_days` (default 90). Rows older than the
window are pruned on every write.

**IP addresses:** off by default. `log_ip_addresses = true` (env
`HEIDRUN_LOG_IP_ADDRESSES`) stores each client's raw IP in audit rows.
Raw IPs are personal data under the GDPR — enable only with a lawful
basis and a retention period you can justify; `audit_retention_days`
bounds how long they persist.

**Disable entirely:** `audit_log_enabled = false` (env
`HEIDRUN_AUDIT_LOG_ENABLED=0`). Replaces the older `user_history_enabled`,
still honoured as an alias.

**Erase the log:** stop the server, delete the `*.audit.sqlite` file,
restart. Because it's a separate file, this leaves accounts and news
untouched.

**Read it back:** the admin chat command
`/audit [--type transfer|auth|admin|presence] [--user <name>] [--since Nh|Nd]
[--limit N]` (`/audit help` prints usage; aliases `/transfers`, `/authlog`,
`/adminlog`; `/usershistory` shows presence). For ad-hoc analysis, query the SQLite file directly — the
schema is one `audit_events` table indexed on `ts`, `(type, ts)`, and
`(account, ts)`.

### Streaming the log (`heidrun-admin log`)

`heidrun-admin log` is the native alternative to `docker logs`: it merges the
structured audit events (joins, transfers, logins, admin actions) with the
server's operational log lines into one live, timestamp-ordered stream.

The operational lines come from an NDJSON file sink the server writes
alongside stderr (`<db_path>.oplog.ndjson` on the shared volume). stderr /
`docker logs` is unchanged — the file is an *additional* sink so `heidrun-admin`
can read the stream off the volume.

```bash
# Last 50 merged records, then exit (a tail):
docker compose exec heidrun heidrun-admin log

# Follow live until Ctrl-C:
docker compose exec heidrun heidrun-admin log -f

# Only warnings and above from the operational side:
docker compose exec heidrun heidrun-admin log -f --source op --level warning

# Only one account's audit trail:
docker compose exec heidrun heidrun-admin log -f --source audit --account alice

# Machine-readable:
docker compose exec heidrun heidrun-admin log -f --json
```

Flags: `-f/--follow`, `--lines N` (backfill, default 50), `--source audit|op|both`,
`--account <login>`, `--level <trace…critical>`, `--type transfer|auth|admin|presence|<kind>`,
`--interval <ms>` (follow poll, default 500), `--op-log-path <path>`, `--json`.

The operational-log file is bounded by size rotation (default 10 MB × 5
archives). Disable it with `operational_log_enabled = false` /
`HEIDRUN_OP_LOG_ENABLED=off`; `heidrun-admin log` then streams audit events only.

## Local administration (`heidrun-admin`)

`heidrun-admin` administers the server's SQLite/news state directly — no
running server required. It reads the same config the server does
(`HEIDRUN_CONFIG` TOML + env), so by default it targets the same DB. Both
binaries ship in the same image; run it via `docker compose exec` (the
compose **service** is named `heidrun`; add `-T` for piped/scripted use):

```bash
docker compose exec heidrun heidrun-admin db info
docker compose exec heidrun heidrun-admin account list
```

To run `heidrun-admin` **natively on the host** (no `docker compose exec`)
against a bind-mounted deployment, see
[`native-host-admin.md`](native-host-admin.md).

Common recipes:

```bash
# Provision an account (password read from stdin, not argv):
printf 's3cret\n' | heidrun-admin account create bob --name Bob --password-stdin --preset guest

# Recover a locked-out admin (reset password + re-grant rights):
printf 'newpass\n' | heidrun-admin account passwd admin --password-stdin
heidrun-admin account privileges admin --grant createUser,deleteUser,modifyUser,disconnectUsers

# Inspect what an account can do:
heidrun-admin account privileges bob --list

# Offline audit query (same filters as the /audit chat command):
heidrun-admin audit --type auth --user bob --since 7d

# One-shot news wipe:
heidrun-admin news reset all --yes
```

> Global options (`--config`, `--db`, `--news-path`, `--files-root`) follow
> the subcommand (e.g. `heidrun-admin account list --db /path`); without them
> the tool resolves the DB from `HEIDRUN_CONFIG`/env exactly like the server.

> Concurrency: the tool and a live server can open the same SQLite file at
> once (WAL). Account changes take effect on the next login / account
> fetch — they don't retroactively change an already-connected session's
> privileges.

## Out of scope (v1)

Deferred to v1.5:

- Persistent file icons (HFS type/creator + comments now persist; icon blobs are still deferred)
- launchd / systemd integration tests
