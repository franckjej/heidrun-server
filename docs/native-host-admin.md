# Native host administration (bind-mounted deployment)

Run the **full-featured `heidrun-admin` CLI natively on the host** that runs
your dockerized HeidrunServer — with the complete command set (`account`,
`audit`, `news`, `db`), no `docker compose exec`, and no protocol/network
client.

## Prerequisites

Building `heidrun-admin` on the host needs a **Swift 6.2+ toolchain** and the
**system SQLite headers** — GRDB compiles against `sqlite3.h`. The Docker
image installs these for you; a native build does not, so install them first
or `swift build` fails with `'sqlite3.h' file not found`:

```bash
# Debian / Ubuntu
sudo apt-get update && sudo apt-get install -y libsqlite3-dev   # build: headers
#                                              libsqlite3-0      # runtime (usually present)
# Fedora / RHEL:  sudo dnf install sqlite-devel
# Alpine:         sudo apk add sqlite-dev
```

## Why this works

`heidrun-admin` is **file-direct**: it administers the server by opening the
SQLite database, audit log, and news JSON *files* — it is not a network
client. The host that runs the Docker daemon shares a filesystem with the
container, so a native host binary can open the *same* files the
containerized server uses. Same machine ⇒ same inode ⇒ SQLite's WAL locking
is honoured across the host process and the container process. So the full
command set works on the host with zero server-side changes.

The trick is to put the server's data on a **host bind mount** (instead of a
Docker named volume) so the host has a stable, known path to those files.

> Want to administer from a **different machine** (no shared filesystem)?
> That needs the over-the-wire admin client (Hotline transactions 350–353),
> which is a separate, more limited surface — see the bottom of this page.

## 1. Bind-mount the data directory

In `docker-compose.yml`, replace the named volume with a host path
(the convention below mirrors a typical `./_data/<service>` layout):

```yaml
    volumes:
      # - heidrun-data:/var/lib/heidrun          # named volume (default)
      - ./_data/heidrun_production:/var/lib/heidrun
```

The image pins the container's `heidrun` user to **UID/GID 1979** (override
at build time with `--build-arg HEIDRUN_UID=… --build-arg HEIDRUN_GID=…`),
so create the host directory and give it to that id:

```bash
mkdir -p ./_data/heidrun_production/files
sudo chown -R 1979:1979 ./_data/heidrun_production
```

After `docker compose up -d --build`, the data sits on the host:

```
./_data/heidrun_production/
├── heidrun.sqlite          # accounts
├── heidrun.audit.sqlite    # audit log
├── heidrun.news.json       # news state
└── files/                  # file tree
```

## 2. Migrate existing data from a named volume (one-time)

If you already run with the default `heidrun-data` named volume, copy its
contents into the bind directory before switching. Keep the old volume until
you've verified the cutover (easy rollback).

```bash
docker compose down

# Copy the named volume's contents into the host bind dir, owned by 1979.
docker run --rm \
  -v heidrun-data:/from \
  -v "$PWD/_data/heidrun_production":/to \
  alpine sh -c 'cp -a /from/. /to/ && chown -R 1979:1979 /to'

# Switch docker-compose.yml to the bind mount (step 1), then:
docker compose up -d --build
docker compose exec heidrun heidrun-admin db info    # verify your account count
```

> The named-volume name is `<project>_heidrun-data` in some setups; run
> `docker volume ls | grep heidrun` if the bare `heidrun-data` isn't found.

## 3. Build the native `heidrun-admin` on the host

See [Prerequisites](#prerequisites) for the toolchain + SQLite headers.

Build with **`--static-swift-stdlib`**: you run the admin as UID 1979 via
`sudo -u`, which resets the environment, so a dynamically-linked binary
fails at startup with `libswiftCore.so: cannot open shared object file`.
Static linking bakes the Swift runtime into the binary so it runs under any
user with a stripped environment.

```bash
git clone https://github.com/franckjej/heidrun-server && cd heidrun-server
swift build -c release --static-swift-stdlib --product heidrun-admin
sudo install -m0755 .build/release/heidrun-admin /usr/local/bin/heidrun-admin
```

(A harmless `mktemp' is dangerous linker warning from Foundation's static
archive is expected — it's upstream, not this project.)

(Alternatively, skip the build and copy the binary straight out of the
image: `docker compose cp heidrun:/usr/local/bin/heidrun-admin /usr/local/bin/`.)

## 4. Administer from the host

Point `--db` at the bind path (the audit log and news JSON are resolved as
siblings automatically). **Just run it as root** — `heidrun-admin`
automatically drops to the owner of the database (e.g. UID 1979), so files
it creates stay owned by the server's user instead of root:

```bash
DB=./_data/heidrun_production/heidrun.sqlite

sudo heidrun-admin db info --db "$DB"
sudo heidrun-admin account list --db "$DB"
sudo heidrun-admin account create bob --name Bob --password-stdin --preset guest --db "$DB"
sudo heidrun-admin audit --type auth --since 7d --db "$DB"
```

`sudo -u '#1979' heidrun-admin …` (explicitly as 1979) also works and is
equivalent. Tip: set `HEIDRUN_DB_PATH=$DB` to drop the `--db` flag, or point
`--config` at the same TOML the server uses. Every command supports
`--help`; read commands also support `--json`.

## Caveats

- **Permissions.** The data files are owned by UID/GID 1979. Run the native
  CLI as root (it auto-drops to the DB's owner) or explicitly as that id
  (`sudo -u '#1979' …`). Running as an unrelated non-root user fails to open
  the DB. The auto-drop is why running as bare root is safe here — without
  it, root would create root-owned `-wal`/`-shm` files that lock the
  container out of its own database.
- **Live concurrency.** SQLite WAL lets the host CLI and the running server
  share the accounts/audit DBs safely. Account changes take effect on the
  next login / account fetch — they don't retroactively alter an
  already-connected session.
- **`news reset` against a running server is racy.** The server holds news
  state in memory and may re-persist over your wipe. Do `news reset` while
  the server is **stopped** (`docker compose stop heidrun`), then start it
  again.

## When you need the network client instead

Direct-file admin only works on the **same host** (SQLite WAL needs a local
filesystem; it does not work over NFS/network shares). To administer from a
**different machine**, you need a Hotline-protocol admin client that logs in
and drives transactions 350–353 over TCP. That surface is more limited —
create/show/delete/passwd/rename/privileges and kick only; there is no
list-all, audit, news-reset, or db-info transaction in the protocol. Until a
dedicated CLI ships, a GUI Hotline client logged in as an admin can perform
those same account operations over the wire.
