# Multi-stage build for HeidrunServer.
#
# Build from this repo's root:
#
#   docker build -t heidrun-server .
#
# Run:
#   docker run -d --name heidrun \
#     -p 5500:5500 -p 5501:5501 \
#     -v heidrun-data:/var/lib/heidrun \
#     -e HEIDRUN_ADMIN_PASSWORD="$(openssl rand -base64 24)" \
#     heidrun-server
#
# State persists in the named volume at /var/lib/heidrun (DB + files
# root). The default config under /etc/heidrun-server/config.toml is
# the bundled `heidrun-server.example.toml` — env vars override it.

# syntax=docker/dockerfile:1.6

# ──────────────────────────────────────────────────────────────────────────────
# git-info stage — derive the short SHA + ISO date surfaced by /version
# ──────────────────────────────────────────────────────────────────────────────
# Tiny alpine + git stage that reads the repo's `.git` and writes two
# small text files the runtime stage copies in. Isolating this in a
# separate stage means a new commit invalidates ONLY this 5 MB image
# layer — the multi-minute swift package resolve and the swift build
# upstream stay cached. The files are picked up by HeidrunServerInfo
# via HEIDRUN_BUILD_INFO_DIR; operators wanting a different stamp
# (CI tag, release tarball without .git) can still override at
# runtime via the HEIDRUN_BUILD / HEIDRUN_BUILD_DATE env vars on the
# container.
FROM alpine:3 AS git-info
RUN apk add --no-cache git
WORKDIR /src
COPY .git ./.git
RUN mkdir -p /out \
 && (git rev-parse --short HEAD 2>/dev/null || echo dev) > /out/build-id \
 && date -u +%Y-%m-%d > /out/build-date

# ──────────────────────────────────────────────────────────────────────────────
# Build stage
# ──────────────────────────────────────────────────────────────────────────────
FROM swift:6.2-jammy AS build

# GRDB links system SQLite; the base image doesn't ship the dev
# headers. `git` + `ca-certificates` let SPM clone HTTPS package
# dependencies.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libsqlite3-dev \
        git \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Bring in the package manifest + sources. Tests/ is needed even
# though we only build the executable product — SPM parses the
# .testTarget declaration during package-graph resolution and fails
# with "overlapping sources" if Tests/HeidrunServerKitTests/ isn't
# present at the path it expects.
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests

# Single RUN: resolve + build + install. heidrun-protocol is fetched
# anonymously over HTTPS — the repo is public. Both the server and the
# `heidrun-admin` CLI ship in the image (the second build reuses the
# shared .build cache, so it only links the extra executable).
RUN --mount=type=cache,target=/root/.cache/org.swift.swiftpm \
    --mount=type=cache,target=/src/.build \
    swift build \
      --configuration release \
      --product HeidrunServer \
 && swift build \
      --configuration release \
      --product heidrun-admin \
 && install -m 0755 \
      .build/release/HeidrunServer \
      /usr/local/bin/heidrun-server \
 && install -m 0755 \
      .build/release/heidrun-admin \
      /usr/local/bin/heidrun-admin

# ──────────────────────────────────────────────────────────────────────────────
# Runtime stage
# ──────────────────────────────────────────────────────────────────────────────
FROM swift:6.2-jammy-slim AS runtime

# GRDB dlopens libsqlite3 at runtime; the slim image doesn't include
# it. tzdata lets a `TZ=Area/City` (set via compose) resolve to a real
# zone so news-post timestamps render in the operator's local time,
# not UTC. netcat-openbsd provides the `nc` binary the compose
# `healthcheck` probe uses (`nc -z 127.0.0.1 5500`); slim images
# don't ship it by default and the probe silently failed forever
# until we noticed the `unhealthy` status on a deployed container.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 tzdata netcat-openbsd \
 && rm -rf /var/lib/apt/lists/*

# A non-root account owns the state directories. /var/lib/heidrun
# itself must be heidrun-owned so a fresh named volume mounted there
# inherits writable permissions for the unprivileged user — otherwise
# GRDB can't create heidrun.sqlite.
#
# The UID/GID are PINNED (not kernel-assigned) so a host bind-mount can be
# chown'd to a known, build-stable id and the native `heidrun-admin` CLI can
# run on the host as that same id against the same files. Override at build
# time with `--build-arg HEIDRUN_UID=… --build-arg HEIDRUN_GID=…`.
# See docs/native-host-admin.md.
ARG HEIDRUN_UID=1979
ARG HEIDRUN_GID=1979
RUN groupadd --system --gid "$HEIDRUN_GID" heidrun \
 && useradd --system --uid "$HEIDRUN_UID" --gid "$HEIDRUN_GID" \
        --home-dir /var/lib/heidrun --shell /usr/sbin/nologin heidrun \
 && install -d -o heidrun -g heidrun /var/lib/heidrun \
 && install -d -o heidrun -g heidrun /var/lib/heidrun/files \
 && install -d -o heidrun -g heidrun /etc/heidrun-server

COPY --from=build /usr/local/bin/heidrun-server /usr/local/bin/heidrun-server
# The offline admin CLI ships alongside the server so operators can run
# `docker compose exec heidrun heidrun-admin …` (see docs/OPERATIONS.md),
# or run it natively on the host against a bind mount (docs/native-host-admin.md).
# It reuses HEIDRUN_CONFIG/HEIDRUN_DB_PATH (set below), so it targets the
# same DB as the running server with no extra flags.
COPY --from=build /usr/local/bin/heidrun-admin /usr/local/bin/heidrun-admin
COPY heidrun-server.example.toml /etc/heidrun-server/config.toml

# Drop the build-id + build-date stamps from the git-info stage into
# a stable path the binary reads at startup. Owned by root + world-
# readable so the unprivileged heidrun user can read them.
COPY --from=git-info /out /usr/local/share/heidrun

USER heidrun
WORKDIR /var/lib/heidrun

ENV HEIDRUN_CONFIG=/etc/heidrun-server/config.toml \
    HEIDRUN_DB_PATH=/var/lib/heidrun/heidrun.sqlite \
    HEIDRUN_FILES_ROOT=/var/lib/heidrun/files \
    HEIDRUN_LOG_LEVEL=info \
    HEIDRUN_BUILD_INFO_DIR=/usr/local/share/heidrun

EXPOSE 5500 5501

# Swift-log writes to stderr; Docker's default logger picks that up.
CMD ["/usr/local/bin/heidrun-server"]
