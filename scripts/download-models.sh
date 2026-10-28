#!/bin/bash
# ============================================================
#  MONAI Platform — Download Pretrained Models (MONAI Zoo)
#
#  Downloads MONAI Bundle zip files to ./models/bundles/ and
#  MONAI Label apps to ./apps/.
#
#  By default, downloads all bundles in the BUNDLES associative
#  array below (brain MRI, lung CT, whole-body CT, pancreas,
#  breast density, VISTA-3D, pathology, prostate, etc.).
#
#  Download sources (tried in order):
#    1. Hugging Face (newer hosting, faster CDN)
#    2. GitHub releases (MONAI Zoo legacy hosting)
#
#  If MONAI is not installed in the current Python env, the
#  script attempts to download inside the running monailabel
#  Docker container instead.
#
#  Usage:
#    ./scripts/download-models.sh              # download all
#    ./scripts/download-models.sh --bundle XYZ  # download one
#    ./scripts/download-models.sh --list         # list available
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLES_DIR="${PROJECT_ROOT}/models/bundles"
APPS_DIR="${PROJECT_ROOT}/apps"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

mkdir -p "$BUNDLES_DIR"

# ── Default bundle set ────────────────────────────────────────
# Associative array of bundle_name → description.
# Keys must match the exact bundle name as published on MONAI Zoo
# (these are also valid model names for MONAI Label's monaibundle app).
# To add a new model, simply add an entry here and re-run the script.
declare -A BUNDLES
BUNDLES=(
    # MRI — Brain tumor (glioma WT/TC/ET)
    [brats_mri_segmentation]="MRI Brain tumor segmentation (SegResNet, BraTS)"
    # CT  — Lung nodule / tumor detection
    [lung_nodule_ct_detection]="CT  Lung nodule detection (RetinaNet, LUNA16)"
    # CT  — Whole body 104-structure segmentation
    [wholeBody_ct_segmentation]="CT  Whole-body 104-structure segmentation"
    # CT  — 13 abdominal organs (SwinUNETR)
    [swin_unetr_btcv_segmentation]="CT  13 abdominal organs (SwinUNETR)"
    # CT  — Pancreas + tumor
    [pancreas_ct_dints_segmentation]="CT  Pancreas + tumor segmentation (DiNTS)"
    # Mammography — breast density classification
    [breast_density_classification]="Mammography breast density classification"
    # Universal interactive 3D segmentation
    [vista3d]="Universal interactive 3D segmentation (VISTA-3D)"
    # Pathology — tumor patch detection (WSI)
    [pathology_tumor_detection]="Pathology WSI tumor detection"
    # Pathology — nuclei segmentation + classification
    [pathology_nuclei_segmentation_classification]="Pathology WSI nuclei seg + classification (HoVerNet)"
    # MRI — Whole brain atlas (133 structures)
    [wholeBrainSeg_Large_UNEST_segmentation]="MRI  Whole brain 133-structure segmentation (UNesT)"
    # MRI — Prostate zones
    [prostate_mri_anatomy]="MRI  Prostate anatomy segmentation"
)

DOWNLOAD_ONE=""
DOWNLOAD_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle) DOWNLOAD_ONE="$2"; shift 2 ;;
        --all)    DOWNLOAD_ALL=true; shift ;;
        --list)
            echo -e "\nAvailable bundles:"
            for k in "${!BUNDLES[@]}"; do
                printf "  %-50s  %s\n" "$k" "${BUNDLES[$k]}"
            done | sort
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# ── Download function ─────────────────────────────────────────
# Downloads a single bundle using MONAI's Python API.
# Tries Hugging Face first (faster CDN), falls back to GitHub.
# Skips download if the bundle directory already exists.
download_bundle() {
    local name="$1"
    local desc="${BUNDLES[$name]:-custom bundle}"

    if [ -d "${BUNDLES_DIR}/${name}" ]; then
        ok "Already exists: $name"
        return
    fi

    info "Downloading: $name  ($desc)"
    # Try Hugging Face first (newer hosting), fall back to GitHub
    python3 -c "
import sys
try:
    from monai.bundle import download
    download('${name}', bundle_dir='${BUNDLES_DIR}', source='huggingface')
    print('[OK] Downloaded from HuggingFace')
except Exception as e1:
    try:
        download('${name}', bundle_dir='${BUNDLES_DIR}')
        print('[OK] Downloaded from GitHub')
    except Exception as e2:
        print(f'[ERROR] Failed: {e1} | {e2}', file=sys.stderr)
        sys.exit(1)
" && ok "$name" || warn "Failed to download: $name (check network or bundle name)"
}

# ── Check Python + MONAI available ──────────────────────────
if ! python3 -c "import monai" &>/dev/null; then
    warn "MONAI not found in current Python environment."
    info "Attempting download inside monailabel container..."
    if docker ps --filter name=monailabel --filter status=running -q | grep -q .; then
        for b in "${!BUNDLES[@]}"; do
            info "Downloading inside container: $b"
            docker exec monailabel python3 -c '
import sys
from monai.bundle import download
b = sys.argv[1]
try:
    download(b, bundle_dir="/workspace/bundles", source="huggingface")
    print("OK (hf):", b)
except Exception:
    try:
        download(b, bundle_dir="/workspace/bundles")
        print("OK (gh):", b)
    except Exception as e:
        print("SKIP:", b, str(e))
' "$b"
        done
        ok "Downloads complete (inside container)"
    else
        warn "monailabel container is not running."
        warn "Start it first with ./scripts/start.sh, then re-run this script."
    fi
    exit 0
fi

# ── Download bundles ──────────────────────────────────────────
if [ -n "$DOWNLOAD_ONE" ]; then
    header "Downloading bundle: $DOWNLOAD_ONE"
    download_bundle "$DOWNLOAD_ONE"
else
    header "Downloading all default MONAI Zoo bundles"
    echo "  Target directory: $BUNDLES_DIR"
    echo ""
    for name in "${!BUNDLES[@]}"; do
        download_bundle "$name"
    done
fi

# ── Download MONAI Label apps ─────────────────────────────────
header "Downloading MONAI Label apps"
mkdir -p "$APPS_DIR"

if python3 -c "import monailabel" &>/dev/null; then
    for app_name in monaibundle radiology pathology; do
        if [ ! -d "${APPS_DIR}/${app_name}" ]; then
            info "Downloading app: $app_name"
            monailabel apps --download --name "$app_name" --output "$APPS_DIR" && \
                ok "Downloaded: $app_name" || warn "Failed: $app_name"
        else
            ok "Already exists: $app_name"
        fi
    done
else
    warn "monailabel CLI not found in current environment. Apps will be downloaded at container startup."
fi

# ── Summary ───────────────────────────────────────────────────
header "Download Summary"
echo "  Bundles dir: $BUNDLES_DIR"
ls -1 "$BUNDLES_DIR" 2>/dev/null | while read -r d; do
    echo "    ✓ $d"
done
echo "  Apps dir: $APPS_DIR"
ls -1 "$APPS_DIR" 2>/dev/null | while read -r d; do
    echo "    ✓ $d"
done
echo ""
ok "All done. Start the platform with: ./scripts/start.sh"
