#!/bin/bash
# ============================================================
#  Click-to-measure a CT lesion with ULS+ (research use only)
#
#  Segments the lesion at a given point and reports volume and RECIST-style
#  long/short axis. Copy the point from 3D Slicer (RAS mm, e.g. a markup's
#  coordinates or the Data Probe) or give a voxel index with --voxel.
#
#  Usage:
#    ./scripts/oncology/measure-lesion.sh --image <ct.nii.gz | DICOM dir> --point=x,y,z [--voxel] [--label name] [--out dir]
#    (use --point=… when the first coordinate is negative, e.g. --point=-161.9,-297.1,-158.0)
#
#  Setup (one time): TotalSegmentator venv (provides nnU-Net v2, see
#  scripts/inference/run-totalseg.sh); ULS+ weights are downloaded on first use to
#  models/uls_plus/ (~0.8 GB, non-commercial research licence — see docs/ONCOLOGY.md).
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOTALSEG_VENV="${TOTALSEG_VENV:-$HOME/.venvs/totalseg}"
PYBIN="${TOTALSEG_VENV}/bin/python"
MODEL_DIR="${PROJECT_ROOT}/models/uls_plus/Dataset090_ULS23_Combined/nnUNetTrainer__nnUNetResEncUNetLPlans__3d_fullres"
HF="https://huggingface.co/nielsRocholl/ULS_plus/resolve/main/nnUNetTrainer__nnUNetResEncUNetLPlans__3d_fullres"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

IMAGE=""; POINT=""; VOXEL=(); LABEL="lesion"; OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --point) POINT="$2"; shift 2 ;;
        --point=*) POINT="${1#--point=}"; shift ;;   # needed when x starts with "-"
        --voxel) VOXEL=(--voxel); shift ;;
        --label) LABEL="$2"; shift 2 ;;
        --out)   OUT="$2"; shift 2 ;;
        *) error "Unknown argument: $1 (see header for usage)" ;;
    esac
done
[ -n "$IMAGE" ] && [ -n "$POINT" ] || error "Specify --image and --point"
[ -x "$PYBIN" ] || error "TotalSegmentator venv not found at $TOTALSEG_VENV (provides nnU-Net v2)"
[[ "$IMAGE" != /* ]] && IMAGE="${PROJECT_ROOT}/${IMAGE}"
[ -e "$IMAGE" ] || error "Image not found: $IMAGE"

# ── ULS+ weights (first use) ──────────────────────────────────
if [ ! -f "${MODEL_DIR}/fold_all/checkpoint_final.pth" ]; then
    info "Downloading ULS+ weights (~0.8 GB) to models/uls_plus/ ..."
    mkdir -p "${MODEL_DIR}/fold_all"
    for f in dataset.json dataset_fingerprint.json plans.json fold_all/checkpoint_final.pth; do
        curl -sfL -o "${MODEL_DIR}/${f}" "${HF}/${f}" || error "download failed: $f"
    done
fi

OUT="${OUT:-${PROJECT_ROOT}/results/$(date +%Y%m%d_%H%M%S)_lesion_${LABEL}}"
mkdir -p "$OUT"

# ── DICOM dir → NIfTI ─────────────────────────────────────────
CT="$IMAGE"
if [ -d "$IMAGE" ]; then
    info "Converting DICOM → NIfTI..."
    CT="${OUT}/ct.nii.gz"
    "$PYBIN" -c "import dicom2nifti,sys; dicom2nifti.dicom_series_to_nifti(sys.argv[1], sys.argv[2], reorient_nifti=True)" "$IMAGE" "$CT"
fi

info "ULS+ segmentation around ${POINT}..."
RESULT=$("$PYBIN" "${SCRIPT_DIR}/lesion_measure.py" "$CT" --point="$POINT" "${VOXEL[@]}" --out "$OUT" --label "$LABEL")
"$PYBIN" - "$RESULT" << 'PYEOF'
import json, sys
r = json.loads(sys.argv[1])
if not r["found"]:
    print("  No lesion segmented at this point — check the coordinates (RAS mm, or --voxel).")
else:
    print(f"  Volume      : {r['volume_ml']} mL")
    print(f"  Long axis   : {r['long_axis_mm']} mm   (axial, RECIST)")
    print(f"  Short axis  : {r['short_axis_mm']} mm   (perpendicular, same slice)")
    print(f"  Centre (RAS): {r['centre_ras_mm']} mm")
PYEOF
ok "Mask: ${OUT}/${LABEL}_mask.nii.gz   (open over the CT in 3D Slicer)"
echo "   Research output only — verify the outline visually."
