# Multi-stage build for HeidrunServer.
#
# Build from the repo root:
#   docker build -t heidrun-server -f Packages/HeidrunServer/Dockerfile .
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

# ──────────────────────────────────────────────────────────────────────────────
# Build stage
# ──────────────────────────────────────────────────────────────────────────────
FROM swift:6.2-jammy AS build

# GRDB links system SQLite; the base image doesn't ship the dev headers.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Copy only the SPM packages HeidrunServer needs to keep the layer
# cache predictable. The macOS-only siblings (HeidrunUI,
# HeidrunModules, CommonTools, HeidrunIconConverter, HeidrunTestServer,
# the Xcode app target) are deliberately excluded.
COPY Packages/HeidrunCore   Packages/HeidrunCore
COPY Packages/HeidrunServer Packages/HeidrunServer

# `--static-swift-stdlib` is intentionally omitted: the runtime image
# already ships the Swift runtime, so static-linking just doubles link
# time. The `.build` cache mount keeps SPM artefacts between builds —
# the install step must live in the same RUN so it can read the cached
# output before the mount detaches.
RUN --mount=type=cache,target=/root/.cache/org.swift.swiftpm \
    --mount=type=cache,target=/src/Packages/HeidrunServer/.build \
    swift build \
      --package-path Packages/HeidrunServer \
      --configuration release \
      --product HeidrunServer \
 && install -m 0755 \
      Packages/HeidrunServer/.build/release/HeidrunServer \
      /usr/local/bin/heidrun-server

# ──────────────────────────────────────────────────────────────────────────────
# Runtime stage
# ──────────────────────────────────────────────────────────────────────────────
FROM swift:6.2-jammy-slim AS runtime

# GRDB dlopens libsqlite3 at runtime; the slim image doesn't include it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 \
 && rm -rf /var/lib/apt/lists/*

# A non-root account owns the state directories.
RUN useradd --system --home-dir /var/lib/heidrun --shell /usr/sbin/nologin heidrun \
 && install -d -o heidrun -g heidrun /var/lib/heidrun/files \
 && install -d -o heidrun -g heidrun /etc/heidrun-server

COPY --from=build /usr/local/bin/heidrun-server /usr/local/bin/heidrun-server
COPY Packages/HeidrunServer/heidrun-server.example.toml /etc/heidrun-server/config.toml

USER heidrun
WORKDIR /var/lib/heidrun

ENV HEIDRUN_CONFIG=/etc/heidrun-server/config.toml \
    HEIDRUN_DB_PATH=/var/lib/heidrun/heidrun.sqlite \
    HEIDRUN_FILES_ROOT=/var/lib/heidrun/files \
    HEIDRUN_LOG_LEVEL=info

EXPOSE 5500 5501

# Swift-log writes to stderr; Docker's default logger picks that up.
CMD ["/usr/local/bin/heidrun-server"]
