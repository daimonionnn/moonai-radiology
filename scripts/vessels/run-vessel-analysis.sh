#!/bin/bash
# ============================================================
#  Renal vessel analysis (research use only — not a medical device)
#
#  Arterial-phase abdominal CT → TotalSegmentator (kidneys, aorta, bone, bowel)
#  → vesselFM vessel segmentation → renal artery branch candidates, Slicer files
#  and a bone/bowel-removed CT for a clean 3D view. Details and limits:
#  docs/VESSEL_ANALYSIS.md
#
#  Setup (one time):
#    TotalSegmentator venv — see scripts/inference/run-totalseg.sh header
#    git clone https://github.com/bwittmann/vesselFM ~/tools/vesselFM
#    uv venv -p 3.11 ~/.venvs/vesselfm
#    VIRTUAL_ENV=~/.venvs/vesselfm uv pip install torch --index-url https://download.pytorch.org/whl/cu128
#    grep -v -E '^(torch|pylibtiff|wandb|gpustat)' ~/tools/vesselFM/requirements.txt > /tmp/vfm_req.txt
#    VIRTUAL_ENV=~/.venvs/vesselfm uv pip install -r /tmp/vfm_req.txt
#
#  Usage:
#    ./scripts/vessels/run-vessel-analysis.sh --image <DICOM dir | NIfTI>
#    ./scripts/vessels/run-vessel-analysis.sh --orthanc-series <Orthanc series ID>
#    options: --out <dir>  --skip-vesselfm
#
#  Env:
#    TOTALSEG_VENV  (default ~/.venvs/totalseg)
#    VESSELFM_VENV  (default ~/.venvs/vesselfm)
#    VESSELFM_DIR   (default ~/tools/vesselFM)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOTALSEG_VENV="${TOTALSEG_VENV:-$HOME/.venvs/totalseg}"
VESSELFM_VENV="${VESSELFM_VENV:-$HOME/.venvs/vesselfm}"
VESSELFM_DIR="${VESSELFM_DIR:-$HOME/tools/vesselFM}"
PYBIN="${TOTALSEG_VENV}/bin/python"
TSBIN="${TOTALSEG_VENV}/bin/TotalSegmentator"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

IMAGE_PATH=""; SERIES_ID=""; RUN_DIR=""; SKIP_VFM=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)           IMAGE_PATH="$2"; shift 2 ;;
        --orthanc-series)  SERIES_ID="$2"; shift 2 ;;
        --out)             RUN_DIR="$2"; shift 2 ;;
        --skip-vesselfm)   SKIP_VFM=1; shift ;;
        *) error "Unknown argument: $1 (see header for usage)" ;;
    esac
done
[ -n "$IMAGE_PATH$SERIES_ID" ] || error "Specify --image <path> or --orthanc-series <id>"
[ -x "$TSBIN" ] || error "TotalSegmentator not found at $TSBIN (see scripts/inference/run-totalseg.sh)"
if [ "$SKIP_VFM" -eq 0 ]; then
    [ -x "${VESSELFM_VENV}/bin/python" ] && [ -f "${VESSELFM_DIR}/vesselfm/seg/inference.py" ] \
        || error "vesselFM not set up (see header), or pass --skip-vesselfm"
fi

NAME="${SERIES_ID:0:8}"; [ -n "$IMAGE_PATH" ] && NAME="$(basename "${IMAGE_PATH%%.nii*}")"
RUN_DIR="${RUN_DIR:-${PROJECT_ROOT}/results/$(date +%Y%m%d_%H%M%S)_vessels_${NAME}}"
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
info "Output: $RUN_DIR"

# ── 1. Input → arterial.nii.gz ────────────────────────────────
if [ -n "$SERIES_ID" ]; then
    ENV_FILE="${PROJECT_ROOT}/docker/.env"
    [ -f "$ENV_FILE" ] || error "docker/.env not found (Orthanc credentials)"
    ORTHANC_USER=$(grep -E '^ORTHANC_USERNAME=' "$ENV_FILE" | cut -d= -f2-)
    ORTHANC_PASS=$(grep -E '^ORTHANC_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)
    ORTHANC_PORT=$(grep -E '^ORTHANC_HTTP_PORT=' "$ENV_FILE" | cut -d= -f2-); ORTHANC_PORT="${ORTHANC_PORT:-8042}"
    info "Exporting series ${SERIES_ID} from Orthanc..."
    curl -sf -u "${ORTHANC_USER}:${ORTHANC_PASS}" \
        "http://localhost:${ORTHANC_PORT}/series/${SERIES_ID}/archive" -o "${RUN_DIR}/series.zip" \
        || error "Orthanc export failed — check the series ID (http://localhost:${ORTHANC_PORT})"
    rm -rf "${RUN_DIR}/dicom" && mkdir -p "${RUN_DIR}/dicom"
    "$PYBIN" -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
        "${RUN_DIR}/series.zip" "${RUN_DIR}/dicom"
    rm -f "${RUN_DIR}/series.zip"
    IMAGE_PATH="${RUN_DIR}/dicom"
fi
[[ "$IMAGE_PATH" != /* ]] && IMAGE_PATH="${PROJECT_ROOT}/${IMAGE_PATH}"
[ -e "$IMAGE_PATH" ] || error "Image not found: $IMAGE_PATH"

if [ -d "$IMAGE_PATH" ]; then
    info "Converting DICOM → NIfTI (dicom2nifti)..."
    "$PYBIN" - "$IMAGE_PATH" "${RUN_DIR}/arterial.nii.gz" << 'PYEOF'
import sys, os, glob, tempfile, shutil, dicom2nifti
src, dst = sys.argv[1], sys.argv[2]
tmpd = tempfile.mkdtemp()
dicom2nifti.convert_directory(src, tmpd, compression=True, reorient=True)
outs = glob.glob(os.path.join(tmpd, "*.nii.gz"))
if not outs: sys.exit("dicom2nifti produced no output")
shutil.move(max(outs, key=os.path.getsize), dst)
shutil.rmtree(tmpd, ignore_errors=True)
PYEOF
else
    cp "$IMAGE_PATH" "${RUN_DIR}/arterial.nii.gz"
fi

# ── 2. TotalSegmentator (full 'total' task, one multi-label file) ─
info "TotalSegmentator (total, multi-label)..."
"$TSBIN" -i "${RUN_DIR}/arterial.nii.gz" -o "${RUN_DIR}/ts_total" --ml -q

# ── 3. ROI + vesselFM input ───────────────────────────────────
info "Kidney/aorta summary and ROI crop:"
"$PYBIN" "${SCRIPT_DIR}/vessel_analysis.py" prepare "$RUN_DIR"

# ── 4. vesselFM ───────────────────────────────────────────────
if [ "$SKIP_VFM" -eq 0 ]; then
    info "vesselFM vessel segmentation (weights download on first run)..."
    ( cd "$VESSELFM_DIR" && PYTHONPATH="$VESSELFM_DIR" "${VESSELFM_VENV}/bin/python" \
        vesselfm/seg/inference.py image_path="${RUN_DIR}/vfm_in" output_folder="${RUN_DIR}/vfm_out" \
        ckpt_path=null 'tta.scales=[0.5,1,1.5]' post.apply=true hydra.run.dir="${RUN_DIR}/vfm_logs" \
        > "${RUN_DIR}/vesselfm.log" 2>&1 ) || error "vesselFM failed — see ${RUN_DIR}/vesselfm.log"

    # ── 5. Post-processing ────────────────────────────────────
    info "Branch origins, Slicer files, bone/bowel removal:"
    "$PYBIN" "${SCRIPT_DIR}/vessel_analysis.py" postprocess "$RUN_DIR"
else
    warn "vesselFM skipped — only the TotalSegmentator summary and ROI were produced"
    ok "Done: ${RUN_DIR}/summary.json"
    exit 0
fi

ok "Done. Open in 3D Slicer (./scripts/vessels/open-vessels-in-slicer.sh \"${RUN_DIR}\"):"
echo "   ${RUN_DIR}/arterial_bone_bowel_removed.nii.gz   (Volume Rendering, preset CT-AAA)"
echo "   ${RUN_DIR}/renal_segmentation.nii.gz            (1 aorta, 2 kidney L, 3 kidney R, 4 arteries)"
echo "   ${RUN_DIR}/renal_artery_candidates.mrk.json     (candidate renal artery origins)"
echo "   ${RUN_DIR}/mip_preview.png                      (quick look)"
warn "Research output only — candidates must be verified visually; stenosis cannot be graded from ~1.25 mm CT."
