#!/bin/bash
# ============================================================
#  Prepare 3D Slicer for MOONAI's oncology / vessel tools (run once, and again
#  after a Slicer upgrade — extensions are per Slicer version):
#    - extensions: NNInteractive, SlicerVMTK, MONAILabel, TotalSegmentator
#    - nninteractive-client in Slicer's Python, Remote mode → local server
#
#  Usage:  ./scripts/oncology/setup-slicer.sh
#  Then:   ./scripts/oncology/nninteractive-server.sh   (keep it running)
#          open Slicer → module "nnInteractive" → Initialize
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/docker/.env"

SLICER="$(command -v slicer3d || ls -d "$HOME"/slicer/current/Slicer 2>/dev/null | head -1)"
[ -x "$SLICER" ] || { echo "3D Slicer not found — run ./scripts/install-slicer.sh"; exit 1; }

PORT=$(grep -E '^NNINTERACTIVE_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
export NNINTERACTIVE_URL="http://localhost:${PORT:-1527}"

echo "Configuring 3D Slicer (downloads extensions, a few minutes the first time)..."
"$SLICER" --no-main-window --python-script "${SCRIPT_DIR}/slicer_setup.py" 2>&1 \
    | grep -E "^\[(OK|FAIL|INFO)\]" || true
