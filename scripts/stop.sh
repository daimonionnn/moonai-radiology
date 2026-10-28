#!/bin/bash
# ============================================================
#  MONAI Platform — Stop EVERYTHING
#
#  Stops and removes all project containers so nothing is left
#  running (and nothing auto-restarts after a reboot — the
#  containers use restart: unless-stopped, which only survives if
#  they are never removed). Covers both the GPU stack
#  (project: monai-platform) and the CPU stack
#  (project: monai-platform-cpu), plus a safety net that removes
#  any leftover container carrying our compose project label.
#
#  Usage:
#    ./scripts/stop.sh                    # stop + remove all project containers
#    ./scripts/stop.sh monailabel         # stop a single service (GPU stack)
#    ./scripts/stop.sh --remove-volumes   # also delete volumes (Orthanc DB!)
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"
COMPOSE_FILE="${DOCKER_DIR}/docker-compose.yml"
CPU_COMPOSE_FILE="${DOCKER_DIR}/docker-compose.cpu.yml"
ENV_FILE="${DOCKER_DIR}/.env"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# ── Resolve Docker Compose (v2 plugin preferred, v1 fallback) ──
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "Docker Compose not found (need 'docker compose' v2 or 'docker-compose' v1)."; exit 1
fi

# Only pass --env-file if it exists (fresh clones may not have one yet).
ENVARG=""; [ -f "$ENV_FILE" ] && ENVARG="--env-file ${ENV_FILE}"

VOLUMES=""
SERVICE=""
for arg in "$@"; do
    case "$arg" in
        --remove-volumes|-v) VOLUMES="-v" ;;
        --*)                 echo "Unknown flag: $arg"; exit 1 ;;
        *)                   SERVICE="$arg" ;;
    esac
done

# ── Single service: just stop it in the GPU stack ─────────────
if [ -n "$SERVICE" ]; then
    info "Stopping service: $SERVICE"
    $DC -f "$COMPOSE_FILE" $ENVARG stop "$SERVICE"
    ok "Done"
    exit 0
fi

# ── Bring down both stacks (idempotent — safe if one isn't up) ─
info "Stopping GPU stack (project: monai-platform)..."
$DC -f "$COMPOSE_FILE" $ENVARG down $VOLUMES 2>/dev/null || true

if [ -f "$CPU_COMPOSE_FILE" ]; then
    info "Stopping CPU stack (project: monai-platform-cpu)..."
    $DC -f "$CPU_COMPOSE_FILE" $ENVARG down $VOLUMES 2>/dev/null || true
fi

# ── Safety net: remove any leftover containers by project label ─
# Catches containers started ad-hoc (e.g. `docker compose -f ... up`
# with a non-default project) that the two `down` calls above missed.
leftover=""
for proj in monai-platform monai-platform-cpu; do
    ids=$(docker ps -aq --filter "label=com.docker.compose.project=${proj}" 2>/dev/null)
    [ -n "$ids" ] && leftover="$leftover $ids"
done
if [ -n "${leftover// /}" ]; then
    warn "Removing leftover project containers:"
    docker rm -f $leftover 2>/dev/null | sed 's/^/    /' || true
fi

# ── Report anything still running that looks like ours ────────
still=$(docker ps --format '{{.Names}}' | grep -iE 'monailabel|orthanc|ohif|tensorboard' || true)
if [ -n "$still" ]; then
    warn "Still running (not managed by this project?): $still"
else
    ok "All MONAI Platform containers stopped and removed."
fi
