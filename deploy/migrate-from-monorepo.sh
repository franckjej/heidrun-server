#!/usr/bin/env bash
#
# One-shot migration helper for hosts that were previously deploying
# HeidrunServer out of the old `franckjej/heidrun-swift` monorepo
# (i.e. the Dockerfile lived at `Packages/HeidrunServer/Dockerfile`).
#
# The script:
#   1. Brings the old container down cleanly so in-flight transfers
#      aren't ripped out from under the network sockets.
#   2. Clones the new dedicated `franckjej/heidrun-server` repo into
#      `/home/src_images_docker/heidrun-server/` (path configurable
#      via $HEIDRUN_REPO_DIR).
#   3. Reuses your existing `heidrun-data` named Docker volume + your
#      `/etc/heidrun-server/tls/` cert directory unchanged — the
#      compose file in the new repo points at the same paths, so the
#      SQLite DB, news JSON, and persistent file metadata all carry
#      across.
#   4. Builds the new image + brings the container up.
#
# Usage:
#     curl -fsSL https://raw.githubusercontent.com/franckjej/heidrun-server/main/deploy/migrate-from-monorepo.sh | sudo bash
# or grab a local copy and:
#     sudo ./migrate-from-monorepo.sh [--dry-run] [--old-repo PATH]
#
# Environment variables:
#     HEIDRUN_REPO_DIR     Where to clone the new repo (default: /home/src_images_docker/heidrun-server)
#     HEIDRUN_OLD_REPO     Old monorepo checkout to drain (default: /home/src_images_docker/heidrun-swift)
#     HEIDRUN_BRANCH        Branch / tag to check out (default: main)

set -euo pipefail

REPO_DIR="${HEIDRUN_REPO_DIR:-/home/src_images_docker/heidrun-server}"
OLD_REPO="${HEIDRUN_OLD_REPO:-/home/src_images_docker/heidrun-swift}"
BRANCH="${HEIDRUN_BRANCH:-main}"
REPO_URL="${HEIDRUN_REPO_URL:-https://github.com/franckjej/heidrun-server.git}"
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --old-repo=*) OLD_REPO="${arg#--old-repo=}" ;;
        --old-repo) shift; OLD_REPO="$1" ;;
        -h|--help)
            sed -n '1,/^set -euo/p' "$0" | sed '$d'
            exit 0 ;;
    esac
done

log()  { printf "\033[36m[migrate]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[migrate]\033[0m %s\n" "$*" >&2; }
run()  {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf "\033[35m[dry-run]\033[0m %s\n" "$*"
    else
        eval "$*"
    fi
}

# 1. Pre-flight: we need docker + git in PATH.
command -v docker >/dev/null || { warn "docker not found in PATH"; exit 1; }
command -v git    >/dev/null || { warn "git not found in PATH"; exit 1; }

# 2. Drain the old container if it's running and we can find the old
#    compose file. Tolerates a partial / non-existent old setup.
OLD_COMPOSE="$OLD_REPO/Packages/HeidrunServer/docker-compose.yml"
if [[ -f "$OLD_COMPOSE" ]]; then
    log "draining old container via $OLD_COMPOSE"
    run "docker compose -f \"$OLD_COMPOSE\" down --remove-orphans"
else
    warn "no old docker-compose.yml at $OLD_COMPOSE — skipping drain"
fi

# 3. Clone the new repo. Idempotent: if the directory already exists,
#    fetch + reset to the target branch instead of erroring out.
if [[ -d "$REPO_DIR/.git" ]]; then
    log "$REPO_DIR already a git repo — fetching + resetting to origin/$BRANCH"
    run "git -C \"$REPO_DIR\" fetch origin"
    run "git -C \"$REPO_DIR\" reset --hard origin/$BRANCH"
else
    log "cloning $REPO_URL into $REPO_DIR (branch: $BRANCH)"
    run "mkdir -p \"$(dirname \"$REPO_DIR\")\""
    run "git clone --branch \"$BRANCH\" \"$REPO_URL\" \"$REPO_DIR\""
fi

# 4. Verify the cert + db volume references match the expected
#    paths. We don't move anything — just check the assumptions hold
#    so the operator sees a clear failure now instead of a confusing
#    container restart loop later.
log "sanity-checking host paths"
[[ -d /var/lib/docker/volumes/heidrun-data/_data ]] && log "  ✓ Docker volume heidrun-data present" \
                                                || warn "  ! Docker volume heidrun-data not found — fresh DB will be initialised"
[[ -f /etc/heidrun-server/tls/fullchain.pem ]] && log "  ✓ TLS fullchain present" \
                                              || warn "  ! /etc/heidrun-server/tls/fullchain.pem not found — TLS listener will fail at startup"
[[ -f /etc/heidrun-server/tls/privkey.pem   ]] && log "  ✓ TLS privkey present" \
                                              || warn "  ! /etc/heidrun-server/tls/privkey.pem not found — TLS listener will fail at startup"

# 5. Build + start. The new docker-compose.yml is at the repo root
#    (Dockerfile too), so the up command no longer needs the long
#    `-f Packages/HeidrunServer/docker-compose.yml` path.
log "building + starting the new heidrun-server container"
run "docker compose -f \"$REPO_DIR/docker-compose.yml\" up -d --build"

log "done. tail logs with:  docker compose -f $REPO_DIR/docker-compose.yml logs -f"
log "next step: verify a TLS client connects on 5502 + a cleartext on 5500"
