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

WORKDIR /src

# Copy only the SPM packages HeidrunServer needs to keep the layer
# cache predictable. The macOS-only siblings (HeidrunUI,
# HeidrunModules, CommonTools, HeidrunIconConverter, HeidrunTestServer,
# the Xcode app target) are deliberately excluded.
COPY Packages/HeidrunCore   Packages/HeidrunCore
COPY Packages/HeidrunServer Packages/HeidrunServer

RUN swift build \
      --package-path Packages/HeidrunServer \
      --configuration release \
      --product HeidrunServer \
      --static-swift-stdlib

# Locate the binary so the runtime stage has a stable path.
RUN install -m 0755 \
      Packages/HeidrunServer/.build/release/HeidrunServer \
      /usr/local/bin/heidrun-server

# ──────────────────────────────────────────────────────────────────────────────
# Runtime stage
# ──────────────────────────────────────────────────────────────────────────────
FROM swift:6.2-jammy-slim AS runtime

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
