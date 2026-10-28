#!/bin/bash
# ============================================================
#  nnInteractive server (DKFZ) — interactive 3D segmentation for 3D Slicer
#  (and other clients): points, scribbles, boxes, lasso → 3D mask.
#  Research use only. Code Apache-2.0, weights CC BY-NC-SA 4.0 (non-commercial).
#
#  Runs on the host from ~/.venvs/nninteractive (PyTorch for CUDA 12.8 — the
#  official Docker image ships PyTorch 2.6, which has no Blackwell/sm_120 kernels).
#
#  Setup (one time):
#    uv venv -p 3.12 ~/.venvs/nninteractive
#    VIRTUAL_ENV=~/.venvs/nninteractive uv pip install torch --index-url https://download.pytorch.org/whl/cu128
#    VIRTUAL_ENV=~/.venvs/nninteractive uv pip install nninteractive
#
#  Usage:  ./scripts/oncology/nninteractive-server.sh     (foreground; Ctrl+C stops)
#  Slicer: install the "nnInteractive" extension, Configuration tab → Remote,
#          URL http://localhost:1527 (./scripts/oncology/setup-slicer.sh sets this up)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/docker/.env"
VENV="${NNINTERACTIVE_VENV:-$HOME/.venvs/nninteractive}"
source "${PROJECT_ROOT}/scripts/lib/compute-device.sh"

[ -x "${VENV}/bin/nninteractive-server" ] || { echo "nnInteractive not installed in ${VENV} — see the setup in this script's header"; exit 1; }

# The server listens on localhost only. An API key is optional: set
# NNINTERACTIVE_API_KEY in docker/.env to require one (Slicer then asks for it each
# session — the extension deliberately does not store keys).
KEY=$(grep -E '^NNINTERACTIVE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
AUTH=(); [ -n "$KEY" ] && AUTH=(--api-key "$KEY")
PORT=$(grep -E '^NNINTERACTIVE_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
PORT="${PORT:-1527}"
DEVICE=cuda; [ "$MOONAI_DEVICE_RESOLVED" = cpu ] && DEVICE=cpu

export NNINTERACTIVE_MODEL_DIR="${PROJECT_ROOT}/models/nninteractive"   # git-ignored
echo "nnInteractive server on http://localhost:${PORT} (device ${DEVICE}); first start downloads the model"
exec "${VENV}/bin/nninteractive-server" --model nnInteractive_v1.0 \
    --host 127.0.0.1 --port "$PORT" --device "$DEVICE" "${AUTH[@]}" --log-level warning
