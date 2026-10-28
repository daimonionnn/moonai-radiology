#!/bin/bash
# ============================================================
#  MONAI Platform — Status Check
#
#  Displays a comprehensive system status dashboard including:
#  - GPU info (model, driver, temperature, VRAM utilisation)
#  - Running containers with ports
#  - Health check of all service HTTP endpoints
#  - Docker image inventory
#  - Disk usage for datasets, models, and storage
#
#  Usage:  ./scripts/status.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"
ENV_FILE="${DOCKER_DIR}/.env"

# Load .env if present
[ -f "$ENV_FILE" ] && source "$ENV_FILE" 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
GRAY='\033[0;37m'

pad() { printf "%-30s" "$1"; }

check_http() {
    local url="$1" auth=()
    [ -n "${2:-}" ] && auth=(-H "Authorization: Bearer $2")
    if curl -sf --max-time 3 "${auth[@]}" "$url" &>/dev/null; then
        echo -e "${GREEN}UP${NC}"
    else
        echo -e "${RED}DOWN${NC}"
    fi
}

echo -e "\n${BOLD}${CYAN}══ MONAI Platform — Status ══${NC}\n"

# ── GPU ────────────────────────────────────────────────────
echo -e "${BOLD}GPU:${NC}"
nvidia-smi --query-gpu=name,driver_version,temperature.gpu,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader 2>/dev/null | while IFS=, read -r name drv temp util memused memtot; do
    printf "  %-30s driver:%-8s  temp:%-6s util:%-6s  VRAM: %s / %s\n" \
        "$name" "$drv" "$temp" "$util" "$memused" "$memtot"
done || echo -e "  ${YELLOW}nvidia-smi not available${NC}"

echo ""
echo -e "${BOLD}Containers:${NC}"
docker ps --format "  {{printf \"%-20s\" .Names}}  {{printf \"%-15s\" .Status}}  {{.Ports}}" \
    --filter "network=monai-platform" 2>/dev/null || \
docker ps --format "  {{printf \"%-20s\" .Names}}  {{printf \"%-15s\" .Status}}  {{.Ports}}" | \
    grep -E "monailabel|orthanc|ohif|tensorboard" || \
    echo -e "  ${YELLOW}No containers running${NC}"

echo ""
echo -e "${BOLD}Service endpoints:${NC}"
printf "  "; pad "MONAI Label API";      check_http "http://localhost:${MONAILABEL_PORT:-8000}/info"
printf "  "; pad "MONAI Label Swagger";  check_http "http://localhost:${MONAILABEL_PORT:-8000}/docs"
printf "  "; pad "OHIF Viewer";          check_http "http://localhost:${OHIF_PORT:-3000}"
printf "  "; pad "Orthanc Web";          check_http "http://localhost:${ORTHANC_HTTP_PORT:-8042}/app"
printf "  "; pad "TensorBoard";          check_http "http://localhost:${TENSORBOARD_PORT:-6006}"
printf "  "; pad "LLM report";           check_http "${LLM_BASE_URL:-http://localhost:1234}/v1/models" "${LLM_API_KEY:-}"

echo ""
echo -e "${BOLD}Docker images:${NC}"
docker images --format "  {{printf \"%-45s\" .Repository}}  {{printf \"%-15s\" .Tag}}  {{.Size}}" | \
    grep -E "monai|orthanc|ohif|tensorflow" || \
    echo -e "  ${YELLOW}No MONAI platform images found${NC}"

echo ""
echo -e "${BOLD}Disk usage:${NC}"
du -sh "${PROJECT_ROOT}/datasets" "${PROJECT_ROOT}/models" "${PROJECT_ROOT}/storage" 2>/dev/null | \
    awk '{printf "  %-12s %s\n", $1, $2}'
echo ""
