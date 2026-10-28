#!/bin/bash
# ============================================================
#  Open a run-vessel-analysis.sh result folder in 3D Slicer:
#  CT in the slice views, bone/bowel-removed CT as volume rendering (CT-AAA),
#  segmentation (aorta, kidneys, arteries) and candidate renal artery origins.
#
#  Usage:  ./scripts/vessels/open-vessels-in-slicer.sh [results/<run_dir>]
#          (without an argument: the newest results/*_vessels_* folder)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RUN_DIR="${1:-$(ls -dt "${PROJECT_ROOT}"/results/*_vessels_* 2>/dev/null | head -1)}"
[ -n "$RUN_DIR" ] || { echo "No results/*_vessels_* folder found — run ./scripts/vessels/run-vessel-analysis.sh first"; exit 1; }
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
[ -f "${RUN_DIR}/arterial_bone_bowel_removed.nii.gz" ] || { echo "Not a vessel-analysis folder: $RUN_DIR"; exit 1; }

SLICER="$(command -v slicer3d || ls -d "$HOME"/slicer/current/Slicer "$HOME"/slicer/Slicer-*/Slicer 2>/dev/null | sort -V | tail -1)"
[ -x "$SLICER" ] || { echo "3D Slicer not found — run ./scripts/install-slicer.sh"; exit 1; }

echo "Opening ${RUN_DIR} in 3D Slicer..."
VESSEL_RUN_DIR="$RUN_DIR" exec "$SLICER" --python-script "${SCRIPT_DIR}/slicer_load_vessels.py"
