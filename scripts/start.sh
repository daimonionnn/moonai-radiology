#!/bin/bash
# ============================================================
#  MONAI Platform — Start Stack
#
#  Launches the full Docker Compose service stack (MONAI Label,
#  Orthanc DICOM server, OHIF viewer, TensorBoard).
#  Waits for the MONAI Label server to become healthy and prints
#  a service table with all endpoint URLs.
#
#  If the custom Docker image or .env file is missing, setup and
#  build are triggered automatically.
#
#  Usage:
#    ./scripts/start.sh                        # start all services
#    ./scripts/start.sh --app monaibundle      # switch app & start
#    ./scripts/start.sh --service monailabel   # start single service
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"
ENV_FILE="${DOCKER_DIR}/.env"
source "${PROJECT_ROOT}/scripts/lib/compute-device.sh"   # sets COMPOSE_FILE (GPU or CPU compose)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

APP=""
SERVICE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)      APP="$2"; shift 2 ;;
        --service)  SERVICE="$2"; shift 2 ;;
        *)          echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ── Update app in .env if requested ──────────────────────────
# --app lets users switch the MONAI Label backend app at launch
# time without needing to edit .env manually.  This is equivalent
# to running switch-app.sh before start.sh.
if [ -n "$APP" ]; then
    valid_apps="monaibundle radiology pathology endoscopy"
    if ! echo "$valid_apps" | grep -qw "$APP"; then
        echo -e "${RED}[ERROR]${NC} Invalid app: $APP. Choose from: $valid_apps"
        exit 1
    fi
    sed -i "s/^MONAILABEL_APP=.*/MONAILABEL_APP=${APP}/" "$ENV_FILE"
    info "Switched MONAI Label app to: $APP"
fi

# ── Validate .env exists ──────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
    warn "docker/.env not found. Running setup first..."
    "${SCRIPT_DIR}/setup.sh"
fi

# ── Require a real Orthanc password (docker/.env, never committed) ──
ORTHANC_PW=$(grep -E '^ORTHANC_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)
if [ -z "$ORTHANC_PW" ] || [ "$ORTHANC_PW" = "change_me" ]; then
    echo "ERROR: set ORTHANC_PASSWORD in docker/.env (it is empty or still 'change_me')." >&2
    exit 1
fi

# ── Validate custom image is built ───────────────────────────
if ! docker image inspect monai-platform/monailabel:latest &>/dev/null; then
    info "Custom MONAI Label image not found. Building..."
    "${SCRIPT_DIR}/build.sh"
fi

header "Starting MONAI Platform"

# ── Resolve Docker Compose (v2 plugin preferred, v1 fallback) ──
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo -e "${RED}[ERROR]${NC} Docker Compose not found (need 'docker compose' v2 or 'docker-compose' v1)."; exit 1
fi

CD_ARGS="-f ${COMPOSE_FILE} --env-file ${ENV_FILE}"
moonai_filter_models_for_cpu
if [ "$MOONAI_DEVICE_RESOLVED" = cpu ]; then
    warn "Running on CPU (MOONAI_DEVICE in docker/.env, or no NVIDIA GPU found) — inference is much slower."
else
    info "Running on NVIDIA GPU."
fi

if [ -n "$SERVICE" ]; then
    info "Starting single service: $SERVICE"
    $DC $CD_ARGS up -d "$SERVICE"
else
    info "Starting all services..."
    $DC $CD_ARGS up -d
fi

# ── Wait for MONAI Label health ───────────────────────────────
# MONAI Label can take 30–60s to start up (model loading).
# Poll the /info endpoint every 5s for up to 5 minutes.
source "$ENV_FILE" 2>/dev/null || true
ML_PORT="${MONAILABEL_PORT:-8000}"

header "Waiting for services to become healthy"
echo -n "  MONAI Label (:$ML_PORT) "
for i in $(seq 1 60); do
    if curl -sf "http://localhost:${ML_PORT}/info" &>/dev/null; then
        echo " ✓"
        break
    fi
    echo -n "."
    sleep 5
done

# ── Print service table ───────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  MONAI Platform — Services Running                       ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}${GREEN}║${NC}  %-22s  %-35s${BOLD}${GREEN}║${NC}\n" "Service" "URL"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}${GREEN}║${NC}  %-22s  %-35s${BOLD}${GREEN}║${NC}\n" "MONAI Label (API)"      "http://localhost:${ML_PORT}"
printf "${BOLD}${GREEN}║${NC}  %-22s  %-35s${BOLD}${GREEN}║${NC}\n" "MONAI Label (Swagger)"  "http://localhost:${ML_PORT}/docs"
printf "${BOLD}${GREEN}║${NC}  %-22s  %-35s${BOLD}${GREEN}║${NC}\n" "OHIF Viewer"            "http://localhost:${OHIF_PORT:-3000}"
printf "${BOLD}${GREEN}║${NC}  %-22s  %-35s${BOLD}${GREEN}║${NC}\n" "Orthanc Web"            "http://localhost:${ORTHANC_HTTP_PORT:-8042}"
printf "${BOLD}${GREEN}║${NC}  %-22s  %-35s${BOLD}${GREEN}║${NC}\n" "TensorBoard"            "http://localhost:${TENSORBOARD_PORT:-6006}"
printf "${BOLD}${GREEN}║${NC}  %-22s  %-35s${BOLD}${GREEN}║${NC}\n" "LLM report"             "${LLM_BASE_URL:-http://localhost:1234}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Logs:${NC}   ./scripts/logs.sh [service]"
echo -e "  ${CYAN}Status:${NC} ./scripts/status.sh"
echo -e "  ${CYAN}Stop:${NC}   ./scripts/stop.sh"
