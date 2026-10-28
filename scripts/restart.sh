#!/bin/bash
# ============================================================
#  MONAI Platform — Restart Stack
#
#  Restarts Docker Compose services in-place (stop + start)
#  without removing containers or volumes.  Useful after
#  changing docker/.env configuration.
#
#  Usage:
#    ./scripts/restart.sh              # restart all services
#    ./scripts/restart.sh monailabel   # restart one service
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"
source "${PROJECT_ROOT}/scripts/lib/compute-device.sh"   # sets COMPOSE_FILE (GPU or CPU compose)
ENV_FILE="${DOCKER_DIR}/.env"

CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }

# ── Resolve Docker Compose (v2 plugin preferred, v1 fallback) ──
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "Docker Compose not found (need 'docker compose' v2 or 'docker-compose' v1)."; exit 1
fi

SERVICE="${1:-}"
CD_ARGS="-f ${COMPOSE_FILE} --env-file ${ENV_FILE}"
moonai_filter_models_for_cpu

if [ -n "$SERVICE" ]; then
    info "Restarting service: $SERVICE"
    $DC $CD_ARGS restart "$SERVICE"
else
    info "Restarting all services..."
    $DC $CD_ARGS restart
fi
