# Multi-stage build for HeidrunServer.
#
# Build from this repo's root. The build needs a GitHub token with read
# access to the private `heidrun-protocol` package — `gh auth token`
# emits one if you've run `gh auth login`:
#
#   DOCKER_BUILDKIT=1 GH_TOKEN="$(gh auth token)" \
#     docker build --secret id=gh_token,env=GH_TOKEN -t heidrun-server .
#
# The token is passed as a BuildKit secret, exposed only inside the
# `swift package resolve` step via $GIT_CONFIG_*, and never written to
# any file or image layer.
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
# dependencies (including the private heidrun-protocol).
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

# Single RUN: resolve + build + install share one auth setup. The
# token is written to a temporary entry in /root/.gitconfig, then
# `--remove-section`'d before the layer commits — git is guaranteed
# to read this config when SPM shells out to it. Three insteadOf
# rewrites cover HTTPS plus both SSH URL shapes so that a cache
# mount carrying an `origin` URL from an earlier build still
# resolves through the authed HTTPS endpoint. If RUN fails before
# the cleanup line, the layer is discarded entirely — the token has
# no path into the final image.
RUN --mount=type=secret,id=gh_token,required=true \
    --mount=type=cache,target=/root/.cache/org.swift.swiftpm \
    --mount=type=cache,target=/src/.build \
    GH_TOKEN="$(cat /run/secrets/gh_token)" \
 && AUTHED_BASE="https://x-access-token:${GH_TOKEN}@github.com/" \
 && git config --global "url.${AUTHED_BASE}.insteadOf" "https://github.com/" \
 && git config --global --add "url.${AUTHED_BASE}.insteadOf" "git@github.com:" \
 && git config --global --add "url.${AUTHED_BASE}.insteadOf" "ssh://git@github.com/" \
 && swift build \
      --configuration release \
      --product HeidrunServer \
 && install -m 0755 \
      .build/release/HeidrunServer \
      /usr/local/bin/heidrun-server \
 && git config --global --remove-section "url.${AUTHED_BASE}"

# ──────────────────────────────────────────────────────────────────────────────
# Runtime stage
# ──────────────────────────────────────────────────────────────────────────────
FROM swift:6.2-jammy-slim AS runtime

# GRDB dlopens libsqlite3 at runtime; the slim image doesn't include it.
# tzdata lets a `TZ=Area/City` (set via compose) resolve to a real zone
# so news-post timestamps render in the operator's local time, not UTC.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 tzdata \
 && rm -rf /var/lib/apt/lists/*

# A non-root account owns the state directories. /var/lib/heidrun
# itself must be heidrun-owned so a fresh named volume mounted there
# inherits writable permissions for the unprivileged user — otherwise
# GRDB can't create heidrun.sqlite.
RUN useradd --system --home-dir /var/lib/heidrun --shell /usr/sbin/nologin heidrun \
 && install -d -o heidrun -g heidrun /var/lib/heidrun \
 && install -d -o heidrun -g heidrun /var/lib/heidrun/files \
 && install -d -o heidrun -g heidrun /etc/heidrun-server

COPY --from=build /usr/local/bin/heidrun-server /usr/local/bin/heidrun-server
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
