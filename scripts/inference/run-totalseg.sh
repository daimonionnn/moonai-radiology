#!/bin/bash
# ============================================================
#  TotalSegmentator runner (alternative CT segmentation engine)
#
#  Runs TotalSegmentator on a CT study and prints per-organ volumes with the
#  SAME reference-range flagging as the MONAI pipeline (process_findings.py),
#  so the two engines can be compared side by side.
#
#  TotalSegmentator is the de-facto standard for CT organ segmentation and
#  handles resampling correctly, so it is a good ground-truth reference for the
#  MONAI bundle output.
#
#  Setup (one time):
#    python3.11 -m venv ~/.venvs/totalseg
#    ~/.venvs/totalseg/bin/pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
#    ~/.venvs/totalseg/bin/pip install TotalSegmentator dicom2nifti
#
#  Usage:
#    ./scripts/inference/run-totalseg.sh --image datasets/ct/<series-dir-or-nifti> [--fast] [--device cpu]
#
#  Env:
#    TOTALSEG_VENV   path to the venv with TotalSegmentator (default ~/.venvs/totalseg)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOTALSEG_VENV="${TOTALSEG_VENV:-$HOME/.venvs/totalseg}"
PYBIN="${TOTALSEG_VENV}/bin/python"
TSBIN="${TOTALSEG_VENV}/bin/TotalSegmentator"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

IMAGE_PATH=""; EXTRA=(); DEVICE="gpu"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)  IMAGE_PATH="$2"; shift 2 ;;
        --fast)   EXTRA+=(--fast); shift ;;
        --device) DEVICE="$2"; shift 2 ;;
        *) error "Unknown argument: $1 (use --image <path> [--fast] [--device gpu|cpu])" ;;
    esac
done

[ -n "$IMAGE_PATH" ] || error "Specify --image <DICOM dir or NIfTI file>"
[ -x "$TSBIN" ] || error "TotalSegmentator not found at $TSBIN. See setup in this script's header (or set TOTALSEG_VENV)."
[[ "$IMAGE_PATH" != /* ]] && IMAGE_PATH="${PROJECT_ROOT}/${IMAGE_PATH}"
[ -e "$IMAGE_PATH" ] || error "Image not found: $IMAGE_PATH"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RUN_DIR="${PROJECT_ROOT}/results/${TIMESTAMP}_totalseg_$(basename "$IMAGE_PATH")"
mkdir -p "$RUN_DIR"
WORK=$(mktemp -d /tmp/totalseg_XXXXX)
trap 'rm -rf "$WORK"' EXIT

# ── Ensure a NIfTI input (convert DICOM dir if needed) ──────────
NIFTI_IN="$IMAGE_PATH"
if [ -d "$IMAGE_PATH" ]; then
    info "Converting DICOM series to NIfTI (dicom2nifti)..."
    NIFTI_IN="${WORK}/input.nii.gz"
    "$PYBIN" - "$IMAGE_PATH" "$NIFTI_IN" << 'PYEOF'
import sys, os, glob, tempfile, shutil, dicom2nifti
src, dst = sys.argv[1], sys.argv[2]
tmpd = tempfile.mkdtemp()
dicom2nifti.convert_directory(src, tmpd, compression=True, reorient=True)
outs = glob.glob(os.path.join(tmpd, "*.nii.gz"))
if not outs: sys.exit("dicom2nifti produced no output")
shutil.move(max(outs, key=os.path.getsize), dst)
shutil.rmtree(tmpd, ignore_errors=True)
PYEOF
fi

# ── Run TotalSegmentator ────────────────────────────────────────
info "Running TotalSegmentator (device=${DEVICE}) — first run downloads weights..."
"$TSBIN" -i "$NIFTI_IN" -o "${RUN_DIR}/segmentations" --statistics --device "$DEVICE" "${EXTRA[@]}"

# ── Print volume table with shared reference-range flagging ──────
info "Volumes (with reference-range flags, shared with the MONAI pipeline):"
"$PYBIN" - "${RUN_DIR}/segmentations" "$SCRIPT_DIR" "$IMAGE_PATH" << 'PYEOF'
import sys, json, os
seg_dir, script_dir, image_path = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, script_dir)
from process_findings import (flag_for, caveat_for, get_modality, get_patient_sex,
                              spleen_length_flag, craniocaudal_length_cm)  # shared logic

stats = json.load(open(os.path.join(seg_dir, "statistics.json")))
vols = sorted(((k, v.get("volume", 0)/1000.0) for k, v in stats.items()),
              key=lambda x: -x[1])
mod, sex = get_modality(image_path), get_patient_sex(image_path)
print(f"\nEngine     : TotalSegmentator")
if mod: print(f"Modality   : {mod}")
print(f"Sex        : {sex or 'unknown (widest reference used)'}")
print(f"{'Structure':<28}{'Volume (ml)':>12}  {'Reference (ml, source)':<34}  Flag")
print(f"{'-'*28}{'-'*12}  {'-'*34}  {'-'*8}")
flagged=[]
for name, vol in vols:
    if vol <= 0: continue
    flag, ref = flag_for(name, vol, sex)
    print(f"{name:<28}{vol:>12.1f}  {ref:<34}  {flag}")
    if flag and flag != "✓":
        note = f" — {caveat_for(name)}" if caveat_for(name) else ""
        flagged.append(f"{name} {vol:.0f}ml ({flag.strip()}{note})")

spleen = os.path.join(seg_dir, "spleen.nii.gz")
if os.path.exists(spleen):
    import nibabel as nib, numpy as np
    img = nib.load(spleen)
    cm = craniocaudal_length_cm(np.asarray(img.dataobj) > 0, img.affine)
    if cm:
        print(f"\nSpleen craniocaudal length: {cm:.1f} cm  {spleen_length_flag(cm, sex)}")
if flagged:
    print("\nOutside reference:", "; ".join(flagged))
print("\nReferences are informational (see REFERENCE_RANGES in process_findings.py); "
      "a flag means 'worth a look', not 'abnormal'.")
PYEOF

ok "TotalSegmentator output saved to: ${RUN_DIR}/segmentations"
