#!/bin/bash
# ============================================================
#  MOONAI — Host Python environment for the helper scripts
#
#  Creates a virtual environment (default ~/.venvs/moonai) with the light
#  host-side dependencies from requirements.txt (pydicom, nibabel, numpy,
#  dicom2nifti, httpx). scripts/inference/* use it automatically.
#
#  Why a venv: modern distributions (Ubuntu 23.04+, Debian 12+) mark the
#  system Python as "externally managed", so `pip install` into it fails.
#
#  TotalSegmentator and vesselFM keep their own venvs (they need a
#  CUDA-matched torch) — see scripts/inference/run-totalseg.sh and
#  scripts/vessels/run-vessel-analysis.sh.
#
#  Usage:  ./scripts/setup-python.sh            (create or update)
#  Env:    MOONAI_VENV  venv path (default ~/.venvs/moonai)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MOONAI_VENV="${MOONAI_VENV:-$HOME/.venvs/moonai}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

command -v python3 >/dev/null || error "python3 not found — install Python 3.10+"

if [ ! -x "${MOONAI_VENV}/bin/python" ]; then
    info "Creating virtual environment: ${MOONAI_VENV}"
    mkdir -p "$(dirname "$MOONAI_VENV")"
    python3 -m venv "$MOONAI_VENV" \
        || error "python3 -m venv failed — on Debian/Ubuntu install it with: sudo apt install python3-venv"
fi

info "Installing requirements.txt..."
"${MOONAI_VENV}/bin/python" -m pip install -q --upgrade pip
"${MOONAI_VENV}/bin/python" -m pip install -q -r "${PROJECT_ROOT}/requirements.txt"

"${MOONAI_VENV}/bin/python" -c "import pydicom, nibabel, numpy, dicom2nifti" \
    || error "Dependencies did not import correctly"
ok "Python environment ready: ${MOONAI_VENV} ($("${MOONAI_VENV}/bin/python" --version))"
