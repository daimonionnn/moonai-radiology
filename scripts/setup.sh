#!/bin/bash
# ============================================================
#  MONAI Platform — Initial Setup Script
#  Run once before first start to configure the environment.
#
#  This script validates all system prerequisites (NVIDIA driver,
#  Docker, Docker Compose, NVIDIA Container Toolkit), creates the
#  docker/.env config, handles NVIDIA NGC container registry login,
#  ensures the required directory hierarchy exists, pulls all base
#  Docker images, and builds the custom MONAI Label image.
#
#  Prerequisites:
#    - NVIDIA driver ≥ 570 (required for Blackwell GPUs: RTX PRO 6000, RTX 50xx)
#    - Docker Engine with Docker Compose v2
#    - NVIDIA Container Toolkit
#
#  Usage:  ./scripts/setup.sh
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

header "MONAI Medical Imaging Platform — Setup"

# ── 1. Environment ───────────────────────────────────────────
# Verify that all critical system dependencies are installed
# and meet minimum version requirements.  Exits with a clear
# error message if any prerequisite is missing.
header "Checking system requirements"

# NVIDIA driver
if ! command -v nvidia-smi &>/dev/null; then
    error "nvidia-smi not found. Install NVIDIA driver ≥ 570 for Blackwell GPU support."
fi
DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
info "NVIDIA driver: $DRIVER_VER"
MAJOR=$(echo "$DRIVER_VER" | cut -d. -f1)
if [ "$MAJOR" -lt 570 ]; then
    error "NVIDIA driver $DRIVER_VER < 570. Blackwell GPUs require driver ≥ 570. Please upgrade."
fi
ok "NVIDIA driver $DRIVER_VER — OK (≥ 570)"

# Docker
if ! command -v docker &>/dev/null; then
    error "Docker not found. Install Docker Engine: https://docs.docker.com/engine/install/ubuntu/"
fi
ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

# Docker Compose v2
if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null 2>&1; then
    error "Docker Compose v2 not found. Install: sudo apt install docker-compose-plugin"
fi
DC=$(command -v docker-compose 2>/dev/null || echo "docker compose")
ok "Docker Compose $(${DC} version --short 2>/dev/null || ${DC} version 2>/dev/null | head -1)"

# NVIDIA Container Toolkit
if ! docker info 2>/dev/null | grep -q "Runtimes.*nvidia\|nvidia.*Runtimes"; then
    warn "NVIDIA Container Toolkit may not be installed."
    warn "Install with:"
    warn "  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmour -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    warn "  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    warn "  sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit"
    warn "  sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
else
    ok "NVIDIA Container Toolkit detected"
fi

# ── 2. Create .env ───────────────────────────────────────────
header "Configuring environment"
if [ ! -f "${DOCKER_DIR}/.env" ]; then
    cp "${DOCKER_DIR}/.env.example" "${DOCKER_DIR}/.env"
    ok "Created docker/.env from example"
else
    ok "docker/.env already exists"
fi

# ── 3. NGC Login — SKIPPED by default ────────────────────────
# The default stack (MONAI Label, Orthanc, OHIF) needs no NGC account.
# NGC is only required for the optional Triton/Holoscan services — if you
# enable those, log in per docs/OPTIONAL_SERVICES.md.
info "Skipping NGC login (not needed for the default stack — see docs/OPTIONAL_SERVICES.md)."

# ── 4. Ensure directories exist ──────────────────────────────
# Create the full directory tree for datasets (organised by
# modality), model storage (bundles + Triton repos), and
# persistent storage (Orthanc DB, logs, TensorBoard events).
header "Ensuring directory structure"
for dir in \
    apps \
    datasets/ct \
    datasets/mri \
    datasets/nifti \
    datasets/xray \
    datasets/mammography \
    datasets/pathology \
    models/bundles \
    models/triton \
    storage/orthanc-db \
    storage/logs \
    storage/tensorboard; do
    mkdir -p "${PROJECT_ROOT}/${dir}"
done
ok "Directory tree ready"

# ── 4b. Host Python environment for the helper scripts ───────
header "Host Python environment"
"${SCRIPT_DIR}/setup-python.sh" || warn "Python environment setup failed — run ./scripts/setup-python.sh later"

# ── 5. Pull public images ────────────────────────────────────
header "Pulling Docker images"
info "Pulling public images (monailabel base, ohif, orthanc, tensorboard)..."
docker pull projectmonai/monailabel:latest 2>&1 | tail -3
docker pull ohif/app:latest                2>&1 | tail -3
docker pull orthancteam/orthanc:latest     2>&1 | tail -3
docker pull tensorflow/tensorflow:latest   2>&1 | tail -3
ok "Public images pulled"

# (Triton/Holoscan NGC images are not pulled — optional, see docs/OPTIONAL_SERVICES.md)

# ── 6. Build custom MONAI Label image ────────────────────────
header "Building custom MONAI Label image (CUDA 12.8 + PyTorch 2.6)"
info "This takes ~10-15 minutes on first run..."
"${SCRIPT_DIR}/build.sh"

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Setup complete!                                 ║${NC}"
echo -e "${GREEN}${BOLD}║                                                  ║${NC}"
echo -e "${GREEN}${BOLD}║  Next steps:                                     ║${NC}"
echo -e "${GREEN}${BOLD}║  1. ./scripts/download-models.sh   (MONAI Zoo)   ║${NC}"
echo -e "${GREEN}${BOLD}║  2. ./scripts/start.sh             (start stack) ║${NC}"
echo -e "${GREEN}${BOLD}║  3. ./scripts/install-slicer.sh    (3D Slicer)   ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
