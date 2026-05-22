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

# Step 1: resolve dependencies from Package.swift + Package.resolved
# alone. This layer is cached as long as those two files don't
# change, so source edits don't re-fetch the whole SPM graph.
#
# The token reaches `swift package resolve` via GIT_CONFIG_COUNT (git
# 2.31+) — a per-process git config that lives only in this shell's
# environment and never touches a config file. Combined with the
# BuildKit secret mount, the token has no path into any image layer:
# the secret file is unmounted when the RUN exits, and the env vars
# die with the shell.
COPY Package.swift Package.resolved ./
RUN --mount=type=secret,id=gh_token,required=true \
    --mount=type=cache,target=/root/.cache/org.swift.swiftpm \
    GH_TOKEN="$(cat /run/secrets/gh_token)" \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="url.https://x-access-token:$(cat /run/secrets/gh_token)@github.com/.insteadOf" \
    GIT_CONFIG_VALUE_0="https://github.com/" \
    swift package resolve

# Step 2: bring in the sources and build. No secret needed here — the
# resolve step already populated the SPM checkout cache, so the build
# step only reads from disk.
COPY Sources ./Sources
RUN --mount=type=cache,target=/root/.cache/org.swift.swiftpm \
    --mount=type=cache,target=/src/.build \
    swift build \
      --configuration release \
      --product HeidrunServer \
 && install -m 0755 \
      .build/release/HeidrunServer \
      /usr/local/bin/heidrun-server

# ──────────────────────────────────────────────────────────────────────────────
# Runtime stage
# ──────────────────────────────────────────────────────────────────────────────
FROM swift:6.2-jammy-slim AS runtime

# GRDB dlopens libsqlite3 at runtime; the slim image doesn't include it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 \
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

USER heidrun
WORKDIR /var/lib/heidrun

ENV HEIDRUN_CONFIG=/etc/heidrun-server/config.toml \
    HEIDRUN_DB_PATH=/var/lib/heidrun/heidrun.sqlite \
    HEIDRUN_FILES_ROOT=/var/lib/heidrun/files \
    HEIDRUN_LOG_LEVEL=info

EXPOSE 5500 5501

# Swift-log writes to stderr; Docker's default logger picks that up.
CMD ["/usr/local/bin/heidrun-server"]
