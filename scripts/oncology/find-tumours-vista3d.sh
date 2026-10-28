#!/bin/bash
# ============================================================
#  Automatic tumour detection on CT with VISTA3D (research use only)
#
#  VISTA3D (MONAI Zoo bundle) has tumour classes that its "segment everything"
#  mode leaves out; they must be requested explicitly. This runs the bundle inside
#  the monailabel container with those classes as the prompt and reports each
#  connected lesion (volume, axial extent). Complements ULS+ (click-to-measure).
#
#  Usage:  ./scripts/oncology/find-tumours-vista3d.sh --image <ct.nii.gz | DICOM dir> [--classes lung,liver,...]
#  Classes: lung (23), pancreas (24), liver (26), colon (27), bone (128); default all
#  Output:  results/<timestamp>_tumours_<name>/  (mask + summary.json)
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYBIN="${TOTALSEG_VENV:-$HOME/.venvs/totalseg}/bin/python"

IMAGE=""; CLASSES="lung,pancreas,liver,colon,bone"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)   IMAGE="$2"; shift 2 ;;
        --classes) CLASSES="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done
[ -n "$IMAGE" ] || { echo "Specify --image"; exit 1; }
[[ "$IMAGE" != /* ]] && IMAGE="${PROJECT_ROOT}/${IMAGE}"
docker ps --format '{{.Names}}' | grep -qx monailabel || { echo "monailabel container not running — ./scripts/start.sh"; exit 1; }

declare -A ID=([lung]=23 [pancreas]=24 [liver]=26 [colon]=27 [bone]=128)
PROMPT=""; for c in ${CLASSES//,/ }; do [ -n "${ID[$c]:-}" ] || { echo "unknown class $c"; exit 1; }; PROMPT+="${PROMPT:+,}${ID[$c]}"; done

NAME="$(basename "${IMAGE%%.nii*}")"
RUN="${PROJECT_ROOT}/results/$(date +%Y%m%d_%H%M%S)_tumours_${NAME}"
mkdir -p "$RUN"
CT="$IMAGE"
if [ -d "$IMAGE" ]; then
    CT="${RUN}/ct.nii.gz"
    "$PYBIN" "${PROJECT_ROOT}/scripts/lib/dicom_to_nifti.py" "$IMAGE" "$CT" || { rm -rf "${RUN:-$OUT}"; exit 1; }
fi
# the container sees the project's results/ and datasets/ only through mounted paths;
# datasets/tmp is the staging area (git-ignored). The container runs as root, so make
# sure the folder stays owned by the host user.
STAGE="${PROJECT_ROOT}/datasets/tmp"
mkdir -p "$STAGE" 2>/dev/null || true
[ -w "$STAGE" ] || docker exec monailabel chown "$(id -u):$(id -g)" /workspace/datasets/tmp
case "$CT" in
    "${PROJECT_ROOT}/datasets/"*) CT_IN="/workspace/datasets/${CT#${PROJECT_ROOT}/datasets/}" ;;
    *) cp "$CT" "${STAGE}/${NAME}.nii.gz"
       CT_IN="/workspace/datasets/tmp/${NAME}.nii.gz" ;;
esac
OUT_IN="/workspace/datasets/tmp/vista_${NAME}_$$"

echo "VISTA3D tumour classes [${CLASSES}] on ${NAME}..."
docker exec -w /workspace/bundles/vista3d -e PYTHONPATH=/workspace/bundles/vista3d monailabel \
    python -m monai.bundle run --config_file configs/inference.json --bundle_root /workspace/bundles/vista3d \
    --input_dict "{'image':'${CT_IN}','label_prompt':[${PROMPT}]}" --output_dir "$OUT_IN" > "${RUN}/vista3d.log" 2>&1 \
    || { echo "VISTA3D failed — see ${RUN}/vista3d.log"; exit 1; }
OUT_HOST="${PROJECT_ROOT}/datasets/${OUT_IN#/workspace/datasets/}"
cp "$(find "$OUT_HOST" -name '*.nii.gz' | head -1)" "${RUN}/tumours_mask.nii.gz"
# files written by the container are owned by root — clean up from inside it
docker exec monailabel rm -rf "$OUT_IN"; rm -f "${PROJECT_ROOT}/datasets/tmp/${NAME}.nii.gz"

"$PYBIN" - "${RUN}/tumours_mask.nii.gz" "$RUN" << 'PYEOF'
import json, sys, numpy as np, nibabel as nib
from scipy import ndimage as ndi
NAMES = {23: "lung tumour", 24: "pancreatic tumour", 26: "hepatic tumour", 27: "colon cancer primary", 128: "bone lesion"}
img = nib.load(sys.argv[1]); a = np.asarray(img.dataobj).astype(int); sp = img.header.get_zooms()[:3]
lesions = []
for cls in sorted(set(np.unique(a)) - {0}):
    lab, n = ndi.label(a == cls, structure=np.ones((3, 3, 3)))
    for i in range(1, n + 1):
        m = lab == i; idx = np.argwhere(m); c = (img.affine @ np.r_[idx.mean(0), 1])[:3]
        ext = [(idx[:, k].max() - idx[:, k].min() + 1) * sp[k] for k in range(3)]
        lesions.append({"class": NAMES.get(cls, str(cls)), "volume_ml": round(float(m.sum() * np.prod(sp) / 1000), 2),
                        "extent_mm": [round(float(e), 1) for e in ext], "centre_ras_mm": [round(float(v), 1) for v in c]})
lesions.sort(key=lambda l: -l["volume_ml"])
json.dump({"lesions": lesions}, open(f"{sys.argv[2]}/summary.json", "w"), indent=1)
print(f"  {len(lesions)} candidate lesion(s)" + ("" if lesions else " — none found"))
for l in lesions:
    print(f"  {l['class']:<22} {l['volume_ml']:>7} mL  extent {l['extent_mm']} mm  centre (RAS) {l['centre_ras_mm']}")
PYEOF
echo "Mask: ${RUN}/tumours_mask.nii.gz — candidates only; verify each visually (and measure with measure-lesion.sh)."
