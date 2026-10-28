#!/bin/bash
# ============================================================
#  MONAI Platform — View Logs
#
#  Streams Docker Compose logs in real-time.  Defaults to
#  following all services with the last 100 lines.  Use
#  --no-follow for a snapshot and --tail N to adjust history.
#
#  Usage:
#    ./scripts/logs.sh                       # all services, follow
#    ./scripts/logs.sh monailabel            # one service, follow
#    ./scripts/logs.sh monailabel --tail 50  # last 50 lines
#    ./scripts/logs.sh --no-follow           # snapshot, no follow
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"
COMPOSE_FILE="${DOCKER_DIR}/docker-compose.yml"
ENV_FILE="${DOCKER_DIR}/.env"

SERVICE=""
TAIL=100
FOLLOW="-f"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tail)     TAIL="$2"; shift 2 ;;
        --no-follow) FOLLOW=""; shift ;;
        -*)         echo "Unknown: $1"; exit 1 ;;
        *)          SERVICE="$1"; shift ;;
    esac
done

# Resolve Docker Compose (v2 plugin preferred, v1 fallback)
if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
else echo "Docker Compose not found."; exit 1; fi

CMD="$DC -f ${COMPOSE_FILE} --env-file ${ENV_FILE} logs ${FOLLOW} --tail=${TAIL}"

if [ -n "$SERVICE" ]; then
    $CMD "$SERVICE"
else
    $CMD
fi
