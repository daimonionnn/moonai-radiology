#!/bin/bash
# ============================================================
#  MONAI Platform — Build Custom Docker Image
#
#  Builds the custom MONAI Label Docker image with:
#  - Base: nvcr.io/nvidia/cuda:12.8.0-cudnn-devel-ubuntu22.04
#  - PyTorch 2.6 (cu128)
#  - MONAI Core + MONAI Label + MONAI Deploy
#  - TorchXRayVision (CXR pathology detection)
#
#  First build takes ~10-15 minutes.  Subsequent builds use
#  Docker layer cache.  Use --no-cache for a clean rebuild.
#
#  Builds:  monai-platform/monailabel:latest
#  Usage:   ./scripts/build.sh [--no-cache]
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }

NO_CACHE=""
for arg in "$@"; do
    [ "$arg" = "--no-cache" ] && NO_CACHE="--no-cache"
done

info "Building monai-platform/monailabel:latest ..."
info "Base image: nvcr.io/nvidia/cuda:12.8.0-cudnn-devel-ubuntu22.04"
info "This installs: PyTorch 2.6 (cu128), MONAI Core, MONAI Label, MONAI Deploy, TorchXRayVision"

DOCKER_BUILDKIT=0 docker build \
    ${NO_CACHE} \
    -t monai-platform/monailabel:latest \
    -f "${DOCKER_DIR}/monailabel/Dockerfile" \
    "${DOCKER_DIR}/monailabel"

ok "Build complete: monai-platform/monailabel:latest"
docker image inspect monai-platform/monailabel:latest \
    --format '{{.RepoTags}} — Size: {{.Size}}' | \
    awk '{printf "  Image size: %.1f GB\n", $NF/1024/1024/1024}'
