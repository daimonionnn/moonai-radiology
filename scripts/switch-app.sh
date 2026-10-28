#!/bin/bash
# ============================================================
#  MONAI Platform — Switch Active MONAI Label App
#
#  MONAI Label supports multiple "apps" (application backends)
#  that determine which models and inference logic are available:
#
#    monaibundle — Generic MONAI Bundle loader (most flexible,
#                  loads any Zoo bundle by name)
#    radiology   — Radiology-specific workflows (DeepEdit, etc.)
#    pathology   — Digital pathology (WSI) workflows
#    endoscopy   — Endoscopy video segmentation
#
#  This script updates MONAILABEL_APP in docker/.env and restarts
#  the monailabel container to activate the selected app.
#
#  Usage:
#    ./scripts/switch-app.sh monaibundle
#    ./scripts/switch-app.sh radiology
#    ./scripts/switch-app.sh pathology
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"
ENV_FILE="${DOCKER_DIR}/.env"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

APPS=(monaibundle radiology pathology endoscopy)
APP="${1:-}"

if [ -z "$APP" ]; then
    echo "Available MONAI Label apps:"
    for a in "${APPS[@]}"; do
        echo "  - $a"
    done
    echo ""
    read -rp "Choose app: " APP
fi

# Validate
valid=false
for a in "${APPS[@]}"; do [ "$a" = "$APP" ] && valid=true; done
$valid || error "Invalid app: $APP. Choose from: ${APPS[*]}"

# Update .env
sed -i "s/^MONAILABEL_APP=.*/MONAILABEL_APP=${APP}/" "$ENV_FILE"
info "Set MONAILABEL_APP=${APP} in docker/.env"

# Restart MONAI Label container
info "Restarting monailabel container..."
"${SCRIPT_DIR}/restart.sh" monailabel
ok "MONAI Label is now running app: $APP"
echo ""
echo "  API:     http://localhost:$(grep MONAILABEL_PORT "$ENV_FILE" | cut -d= -f2)/info"
echo "  Swagger: http://localhost:$(grep MONAILABEL_PORT "$ENV_FILE" | cut -d= -f2)/docs"
