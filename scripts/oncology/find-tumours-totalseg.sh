#!/bin/bash
# ============================================================
#  Automatic tumour candidates on CT with TotalSegmentator (research use only)
#
#  Runs TotalSegmentator's lesion tasks and lists each connected lesion (volume,
#  extent, centre). Same output format as find-tumours-vista3d.sh, so the two can be
#  compared; candidates found by both models are more trustworthy.
#
#  Usage:  ./scripts/oncology/find-tumours-totalseg.sh --image <ct.nii.gz | DICOM series dir> [--classes lung,liver,kidney]
#  Classes (TotalSegmentator task): lung = lung_nodules, liver = liver_lesions,
#           kidney = kidney_cysts (cysts, NOT solid tumours). Default: lung,liver
#  Output:  results/<timestamp>_tumours-totalseg_<name>/  (tumours_mask.nii.gz + summary.json)
#  Mask labels: 1 lung nodule, 2 liver lesion, 3 kidney cyst
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOTALSEG_VENV="${TOTALSEG_VENV:-$HOME/.venvs/totalseg}"
PYBIN="${TOTALSEG_VENV}/bin/python"
TSBIN="${TOTALSEG_VENV}/bin/TotalSegmentator"
source "${PROJECT_ROOT}/scripts/lib/compute-device.sh"

IMAGE=""; CLASSES="lung,liver"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)   IMAGE="$2"; shift 2 ;;
        --classes) CLASSES="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done
[ -n "$IMAGE" ] || { echo "Specify --image"; exit 1; }
[ -x "$TSBIN" ] || { echo "TotalSegmentator not found at $TSBIN (see scripts/inference/run-totalseg.sh)"; exit 1; }
[[ "$IMAGE" != /* ]] && IMAGE="${PROJECT_ROOT}/${IMAGE}"
[ -e "$IMAGE" ] || { echo "Image not found: $IMAGE"; exit 1; }

declare -A TASK=([lung]=lung_nodules [liver]=liver_lesions [kidney]=kidney_cysts)
for c in ${CLASSES//,/ }; do [ -n "${TASK[$c]:-}" ] || { echo "unknown class $c (lung, liver, kidney)"; exit 1; }; done

NAME="$(basename "${IMAGE%%.nii*}")"
RUN="${PROJECT_ROOT}/results/$(date +%Y%m%d_%H%M%S)_tumours-totalseg_${NAME}"
mkdir -p "$RUN"
CT="$IMAGE"
if [ -d "$IMAGE" ]; then
    CT="${RUN}/ct.nii.gz"
    "$PYBIN" "${PROJECT_ROOT}/scripts/lib/dicom_to_nifti.py" "$IMAGE" "$CT" || { rm -rf "$RUN"; exit 1; }
fi

echo "TotalSegmentator lesion tasks [${CLASSES}] on ${NAME} (device ${MOONAI_DEVICE_RESOLVED})..."
for c in ${CLASSES//,/ }; do
    "$TSBIN" -i "$CT" -o "${RUN}/ts_${TASK[$c]}" --task "${TASK[$c]}" --device "$MOONAI_DEVICE_RESOLVED" -q \
        > "${RUN}/ts_${TASK[$c]}.log" 2>&1 || { echo "TotalSegmentator ${TASK[$c]} failed — see ${RUN}/ts_${TASK[$c]}.log"; exit 1; }
done

"$PYBIN" - "$RUN" "$CLASSES" << 'PYEOF'
import json, os, sys, numpy as np, nibabel as nib
from scipy import ndimage as ndi
run, classes = sys.argv[1], sys.argv[2].split(",")
# class → (mask files written by the task, label in the combined mask, display name)
SPEC = {"lung":   (["ts_lung_nodules/lung_nodules.nii.gz"], 1, "lung nodule"),
        "liver":  (["ts_liver_lesions/liver_lesions.nii.gz"], 2, "liver lesion"),
        "kidney": (["ts_kidney_cysts/kidney_cyst_left.nii.gz", "ts_kidney_cysts/kidney_cyst_right.nii.gz"], 3, "kidney cyst")}
ref = None; combined = None; lesions = []
for c in classes:
    files, label, name = SPEC[c]
    for f in files:
        img = nib.load(os.path.join(run, f)); m = np.asarray(img.dataobj) > 0
        if ref is None:
            ref = img; combined = np.zeros(m.shape, np.uint8)
        combined[m] = label
        sp = img.header.get_zooms()[:3]
        lab, n = ndi.label(m, structure=np.ones((3, 3, 3)))
        for i in range(1, n + 1):
            r = lab == i; idx = np.argwhere(r); ctr = (img.affine @ np.r_[idx.mean(0), 1])[:3]
            ext = [(idx[:, k].max() - idx[:, k].min() + 1) * sp[k] for k in range(3)]
            lesions.append({"class": name, "volume_ml": round(float(r.sum() * np.prod(sp) / 1000), 2),
                            "extent_mm": [round(float(e), 1) for e in ext],
                            "centre_ras_mm": [round(float(v), 1) for v in ctr]})
nib.save(nib.Nifti1Image(combined, ref.affine), os.path.join(run, "tumours_mask.nii.gz"))
lesions.sort(key=lambda l: -l["volume_ml"])
json.dump({"engine": "TotalSegmentator", "lesions": lesions}, open(os.path.join(run, "summary.json"), "w"), indent=1)
print(f"  {len(lesions)} candidate lesion(s)" + ("" if lesions else " — none found"))
for l in lesions:
    print(f"  {l['class']:<14} {l['volume_ml']:>7} mL  extent {l['extent_mm']} mm  centre (RAS) {l['centre_ras_mm']}")
PYEOF
echo "Mask: ${RUN}/tumours_mask.nii.gz — candidates only; verify each visually (and measure with measure-lesion.sh)."
