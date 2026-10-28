#!/bin/bash
# ============================================================
#  MONAI Platform — Run Inference + Generate LLM Report
#
#  By default, findings and the LLM report are auto-saved to:
#    results/YYYYMMDD_HHMMSS_<model>_<patient/dataset>_findings.json
#    results/YYYYMMDD_HHMMSS_<model>_<patient/dataset>_report.txt
#
#  Flags:
#    --model <name>          MONAI Label model to run
#    --image <path>          NIfTI file or DICOM series directory
#    --no-llm                Skip LLM report generation
#    --output <file>         Override findings save path (explicit JSON path)
#    --no-save-findings      Do NOT auto-save findings JSON
#    --no-save-report        Do NOT auto-save LLM report
#    --no-free-vram          Skip VRAM release step between inference and LLM
#    --no-unload-llm         Skip LLM unload step before inference
#    --list-models           List all loaded models and exit
#
#  Examples:
#    ./scripts/inference/run-inference.sh \
#        --model wholeBrainSeg_Large_UNEST_segmentation \
#        --image datasets/mri/<series>
#
#    ./scripts/inference/run-inference.sh --model lung_nodule_ct_detection \
#        --image datasets/ct/<series> \
#        --no-llm --no-save-report
#
#    ./scripts/inference/run-inference.sh --list-models
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/docker/.env"

[ -f "$ENV_FILE" ] && source "$ENV_FILE" 2>/dev/null || true

ML_HOST="localhost"
ML_PORT="${MONAILABEL_PORT:-8000}"
ML_URL="http://${ML_HOST}:${ML_PORT}"
LLM_URL="${LLM_BASE_URL:-http://localhost:1234}"
LLM_MODEL_NAME="${LLM_MODEL:-llama-3.1-8b-instruct}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

COMPOSE_FILE="${PROJECT_ROOT}/docker/docker-compose.yml"

MODEL=""
IMAGE_PATH=""
NO_LLM=false
OUTPUT_JSON=""
AUTO_SAVE_FINDINGS=true
AUTO_SAVE_REPORT=true
FREE_VRAM=true
UNLOAD_LLM=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)             MODEL="$2"; shift 2 ;;
        --image)             IMAGE_PATH="$2"; shift 2 ;;
        --no-llm)            NO_LLM=true; shift ;;
        --output)            OUTPUT_JSON="$2"; shift 2 ;;
        --no-save-findings)  AUTO_SAVE_FINDINGS=false; shift ;;
        --no-save-report)    AUTO_SAVE_REPORT=false; shift ;;
        --no-free-vram)      FREE_VRAM=false; shift ;;
        --no-unload-llm)     UNLOAD_LLM=false; shift ;;
        --list-models)
            info "Fetching available models from MONAI Label..."
            curl -sfL "${ML_URL}/info/" | python3 -c "
import json,sys
info=json.load(sys.stdin)
models=info.get('models',{})
print('\nAvailable models:')
for k,v in models.items():
    print(f'  {k:<50}  {v.get(\"description\",\"\")[:60]}')
"
            exit 0 ;;
        *) error "Unknown argument: $1. Use --model, --image, --no-llm, --output, --no-save-findings, --no-save-report, --no-free-vram, --no-unload-llm" ;;
    esac
done

# ── Unload LLM from LM Studio before inference so VRAM is available ──────────
# LM Studio keeps the LLM weights resident in GPU VRAM even when idle.
# Before running MONAI Label inference (which also needs GPU VRAM for the
# segmentation/detection model), we proactively unload the LLM to prevent
# CUDA out-of-memory errors.  LM Studio will JIT-reload the model when
# the next /v1/chat/completions request arrives.
#
# Flow:
#   1. Query GET /api/v1/models to discover loaded model instances
#   2. Parse instance_ids from the JSON response (Python inline)
#   3. POST /api/v1/models/unload for each instance_id
#   4. If LM Studio is unreachable, skip gracefully (non-fatal)
unload_llm_vram() {
    local llm_url="$1"

    # Try v1 API first, fall back to v0 (older LM Studio versions)
    local models_json
    models_json=$(curl -sf --max-time 5 "${llm_url}/api/v1/models" 2>/dev/null) || {
        models_json=$(curl -sf --max-time 5 "${llm_url}/api/v0/models" 2>/dev/null) || true
    }

    if [ -z "$models_json" ]; then
        warn "Cannot reach LM Studio at ${llm_url} — skipping LLM unload."
        return 0
    fi

    # Extract instance_ids of all loaded model instances.
    # The v1 API returns:
    #   {"models": [{"loaded_instances": [{"instance_id": "..."}]}]}
    # The v0 API returns:
    #   {"data": [{"id": "...", "state": "loaded"}]}
    # We handle both formats in the Python snippet below.
    local instance_ids
    instance_ids=$(python3 - "$models_json" << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
# v1 API: models list with loaded_instances[].instance_id
models = data.get('models', [])
for model in models:
    for inst in model.get('loaded_instances', []):
        iid = inst.get('instance_id') or inst.get('id')
        if iid:
            print(iid)
# v0 API fallback: data[].id where state==loaded
for model in data.get('data', []):
    if model.get('state') == 'loaded':
        print(model.get('id', ''))
PYEOF
)

    if [ -z "$instance_ids" ]; then
        info "No LLM loaded in LM Studio — VRAM already available."
        return 0
    fi

    # Iterate over discovered instance IDs and issue unload requests.
    # Each unload frees the model weights from GPU VRAM.
    local unloaded=0
    while IFS= read -r iid; do
        [ -z "$iid" ] && continue
        local resp http_code
        # POST the unload request with the instance_id in the JSON body
        resp=$(curl -sf --max-time 10 -w "\n%{http_code}" \
            -X POST "${llm_url}/api/v1/models/unload" \
            -H "Content-Type: application/json" \
            -d "{\"instance_id\":\"${iid}\"}" 2>/dev/null)
        http_code=$(echo "$resp" | tail -1)
        # Accept HTTP 200 or a response containing instance_id as success
        if [ "$http_code" = "200" ] || echo "$resp" | grep -q '"instance_id"'; then
            ok "Unloaded LLM from LM Studio: $iid"
            unloaded=$(( unloaded + 1 ))
        else
            warn "Could not unload '$iid' (HTTP $http_code) — continuing."
        fi
    done <<< "$instance_ids"

    [ "$unloaded" -gt 0 ] && info "GPU VRAM freed — LM Studio will JIT-reload the model when needed."
    return 0
}

# ── VRAM free: restart monailabel container so LLM can use the GPU ───────────
# After inference completes, the MONAI Label server may still hold GPU VRAM
# for the loaded segmentation model.  If we plan to call the LLM next, we
# restart the monailabel container to release GPU memory, then wait for the
# server to become healthy again before proceeding.
free_monailabel_vram() {
    local ml_url="$1"
    local timeout_s=60
    info "Restarting monailabel container to free GPU VRAM for LLM ..."

    # Use docker compose (v2) with fallback to docker-compose (v1)
    if docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" restart monailabel \
           >/dev/null 2>&1; then
        : # success
    elif docker-compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" restart monailabel \
           >/dev/null 2>&1; then
        : # success
    else
        warn "Could not restart monailabel container — VRAM may not be freed."
        return 1
    fi

    # Wait for the server to become healthy again
    local deadline=$(( $(date +%s) + timeout_s ))
    printf '  Waiting for monailabel to come back online'
    while true; do
        if curl -sf --max-time 2 "${ml_url}/info/" >/dev/null 2>&1; then
            echo ''
            ok "monailabel is back online — GPU VRAM freed."
            return 0
        fi
        if [ $(date +%s) -ge $deadline ]; then
            echo ''
            warn "monailabel did not respond within ${timeout_s}s — continuing anyway."
            return 1
        fi
        printf '.'
        sleep 2
    done
}

[ -z "$MODEL" ]      && error "Specify a model with --model <name>. Use --list-models to see available."
[ -z "$IMAGE_PATH" ] && error "Specify an image with --image <path>"

# Make path absolute
if [[ "$IMAGE_PATH" != /* ]]; then
    IMAGE_PATH="${PROJECT_ROOT}/${IMAGE_PATH}"
fi
[ -e "$IMAGE_PATH" ] || error "Image not found: $IMAGE_PATH"

# ── Build auto-save slug from image path + DICOM metadata ────
# Generate a human-readable directory name for saving results.
# For DICOM series, we extract patient name, study description,
# modality, and date from the DICOM header of the first file.
# Falls back to the last 3 path components if pydicom is unavailable
# or the path is not a DICOM directory.
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
IMAGE_SLUG=$(python3 - "$IMAGE_PATH" << 'PYEOF'
import sys, os, re
image_path = sys.argv[1]
patient_info = ""
if os.path.isdir(image_path):
    try:
        import pydicom
        files = sorted([f for f in os.listdir(image_path) if not f.startswith('.')])
        if files:
            dcm = pydicom.dcmread(os.path.join(image_path, files[0]), stop_before_pixels=True)
            name       = str(getattr(dcm, 'PatientName',      '') or '').replace('^', '_').strip('_')
            patient_id = str(getattr(dcm, 'PatientID',        '') or '').strip()
            study_desc = str(getattr(dcm, 'StudyDescription', '') or '').strip()
            series_desc= str(getattr(dcm, 'SeriesDescription','') or '').strip()
            study_date = str(getattr(dcm, 'StudyDate',        '') or '').strip()
            modality   = str(getattr(dcm, 'Modality',         '') or '').strip()
            parts = [p for p in [name or patient_id, series_desc or study_desc, modality, study_date] if p]
            patient_info = '_'.join(parts[:4])
    except Exception:
        pass
if not patient_info:
    # Fallback: last 3 meaningful path components
    path_parts = [p for p in image_path.rstrip('/').split('/') if p]
    patient_info = '_'.join(path_parts[-3:])
slug = re.sub(r'[^a-zA-Z0-9_\-]', '_', patient_info)
slug = re.sub(r'_+', '_', slug).strip('_')
print(slug[:60])
PYEOF
)

RESULTS_DIR="${PROJECT_ROOT}/results"
RUN_DIR="${RESULTS_DIR}/${TIMESTAMP}_${MODEL}_${IMAGE_SLUG}"

# ── Pre-flight: verify model is loaded ───────────────────────
# Query the MONAI Label server's /info/ endpoint to get the list
# of currently loaded models.  If the requested model is not in
# the list, print helpful instructions and exit.
AVAILABLE=$(curl -sL "${ML_URL}/info/" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(','.join(d.get('models',{}).keys()))
except: print('')
" 2>/dev/null)

if [ -z "$AVAILABLE" ]; then
    error "Cannot reach MONAI Label at ${ML_URL}. Is the platform running? (./scripts/start.sh)"
fi

if ! echo "$AVAILABLE" | tr ',' '\n' | grep -qx "$MODEL"; then
    echo ""
    warn "Model '$MODEL' is not loaded in MONAI Label."
    echo "  Loaded models: $(echo $AVAILABLE | tr ',' ' ')"
    echo ""
    echo "  To load '$MODEL', add it to MONAILABEL_MODELS in docker/.env:"
    echo "    MONAILABEL_MODELS=${AVAILABLE},${MODEL}"
    echo "  Then restart: docker-compose -f docker/docker-compose.yml --env-file docker/.env restart monailabel"
    exit 1
fi

# ── Pre-flight: check GPU memory ─────────────────────────────
# Warn early if GPU VRAM is critically low (<2 GiB free).
# This is informational only — inference may still succeed for
# smaller models, but large models (e.g. wholeBody_ct_segmentation)
# typically need 4-8 GiB.
if command -v nvidia-smi &>/dev/null; then
    GPU_FREE_MIB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    GPU_TOTAL_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    if [ -n "$GPU_FREE_MIB" ] && [ "$GPU_FREE_MIB" -lt 2000 ] 2>/dev/null; then
        warn "Very low GPU memory: ${GPU_FREE_MIB} MiB free / ${GPU_TOTAL_MIB} MiB total"
        echo "  Inference may fail with CUDA out-of-memory."
    fi
fi

# ── Unload LLM from LM Studio before inference ───────────────
if [ "$UNLOAD_LLM" = true ]; then
    unload_llm_vram "$LLM_URL" || true
else
    info "Skipping LLM unload (--no-unload-llm)."
fi

# ── Run inference ─────────────────────────────────────────────
# We ALWAYS upload a NIfTI file: POST /infer/{model} with file=@image.nii.gz
#
# NOTE (important): we deliberately do NOT use the DICOM /session/ upload path.
# That path lets MONAI Label convert DICOM→NIfTI internally, but its converted
# geometry breaks the bundle's resample-back (Invertd), so the returned mask is
# badly under-filled — e.g. liver came out 226 cm³ instead of ~1580 cm³. Doing
# the DICOM→NIfTI conversion on the host (dicom2nifti, reorient=True) and
# uploading that NIfTI produces correct volumes. So: if the image is a DICOM
# directory we convert it first, then upload the resulting .nii.gz.
#
# The response is multipart/form-data with two parts:
#   "params" → JSON (label_names, boxes, scores, latencies)
#   "image"  → binary NIfTI segmentation mask
echo ""
info "Model:  $MODEL"
info "Image:  $IMAGE_PATH"
info "Server: $ML_URL"
echo ""

TMPFILE=$(mktemp /tmp/monai_infer_XXXXX.json)
NIFTI_TMP=""          # set when we convert a DICOM dir; removed on exit
UPLOAD_FILE="$IMAGE_PATH"

# If image path is a directory (DICOM series), convert it to NIfTI on the host.
if [ -d "$IMAGE_PATH" ]; then
    info "Image is a DICOM directory — converting to NIfTI on host (dicom2nifti)..."
    NIFTI_TMP=$(mktemp -u /tmp/monai_nifti_XXXXX.nii.gz)
    if ! python3 - "$IMAGE_PATH" "$NIFTI_TMP" << 'PYEOF'
import sys, os, glob, tempfile, shutil
try:
    import dicom2nifti
except ImportError:
    sys.stderr.write("dicom2nifti not installed. Install:  python3 -m pip install dicom2nifti\n")
    sys.exit(2)
src, dst = sys.argv[1], sys.argv[2]
tmpd = tempfile.mkdtemp()
try:
    # reorient=True gives clean, consistent voxel geometry — required for the
    # bundle's resample-back to work correctly.
    dicom2nifti.convert_directory(src, tmpd, compression=True, reorient=True)
    outs = glob.glob(os.path.join(tmpd, "*.nii.gz"))
    if not outs:
        sys.stderr.write("dicom2nifti produced no NIfTI output\n"); sys.exit(3)
    shutil.move(max(outs, key=os.path.getsize), dst)   # largest = the main series
finally:
    shutil.rmtree(tmpd, ignore_errors=True)
PYEOF
    then
        warn "DICOM→NIfTI conversion failed."
        rm -f "$TMPFILE" "$NIFTI_TMP"
        exit 1
    fi
    UPLOAD_FILE="$NIFTI_TMP"
    info "Converted → $(du -sh "$NIFTI_TMP" | cut -f1) NIfTI"
fi

info "Running inference (this may take a few minutes)..."
HTTP_CODE=$(curl -sL -w "%{http_code}" \
    -X POST \
    "${ML_URL}/infer/${MODEL}" \
    -H "accept: application/json" \
    -F "params={\"result_extension\":\".nii.gz\"}" \
    -F "file=@${UPLOAD_FILE}" \
    -o "$TMPFILE" 2>/dev/null) || HTTP_CODE=0

# Remove the temporary converted NIfTI (original DICOM dir is untouched).
[ -n "$NIFTI_TMP" ] && rm -f "$NIFTI_TMP"

if [ "$HTTP_CODE" -eq 200 ] 2>/dev/null; then
    ok "Inference complete (HTTP 200)"
    # MONAI Label returns multipart/form-data; extract the 'params' JSON part
    FINDINGS_JSON=$(python3 - "$TMPFILE" << 'PYEOF'
import sys, re, json
content = open(sys.argv[1], 'rb').read().decode('utf-8', errors='replace')
match = re.search(r'name="params"[^\r\n]*\r?\n(?:Content-Type:[^\r\n]*\r?\n)?\r?\n(\{.*?\})(?:\r?\n--)', content, re.DOTALL)
if match:
    print(match.group(1))
else:
    try:
        print(json.dumps(json.loads(content), indent=2))
    except Exception:
        print(content)
PYEOF
)

    # ── Compute rich clinical summary from multipart response ──────────
    # process_findings.py does the heavy lifting:
    #   - Extracts the NIfTI segmentation mask from the multipart body
    #   - Loads original DICOM/NIfTI metadata for spacing comparison
    #   - Computes per-structure volumes in cm³ using voxel counting
    #   - Warns if output spacing differs from original (resampling)
    #   - Formats detection boxes and classification scores
    # The output is a structured text block passed to the LLM as context.
    CLINICAL_SUMMARY=$(python3 "${SCRIPT_DIR}/process_findings.py" \
        --tmpfile "$TMPFILE" \
        --model   "$MODEL" \
        --image   "$IMAGE_PATH" \
        --server  "$ML_URL" 2>/dev/null \
        || echo "Clinical summary unavailable — run process_findings.py manually")

    echo ""
    echo -e "${BOLD}Findings:${NC}"
    echo "$CLINICAL_SUMMARY"
else
    warn "Inference returned HTTP $HTTP_CODE"
    echo "Server response:"
    cat "$TMPFILE" 2>/dev/null | python3 -m json.tool 2>/dev/null || cat "$TMPFILE" 2>/dev/null
    rm -f "$TMPFILE"
    exit 1
fi

# ── Save findings JSON ───────────────────────────────────────
if [ -n "$OUTPUT_JSON" ]; then
    # Explicit path overrides auto-save for findings
    mkdir -p "$(dirname "$OUTPUT_JSON")"
    echo "$FINDINGS_JSON" > "$OUTPUT_JSON"
    ok "Saved findings JSON to: $OUTPUT_JSON"
elif [ "$AUTO_SAVE_FINDINGS" = true ]; then
    mkdir -p "$RUN_DIR"
    echo "$FINDINGS_JSON" > "${RUN_DIR}/findings.json"
    ok "Auto-saved findings to: ${RUN_DIR}/findings.json"
fi

# ── Free GPU VRAM before LLM call ───────────────────────────
# The MONAI Label server holds GPU memory for the loaded inference model.
# If we're about to call the LLM (which also needs VRAM), restart the
# monailabel container to free GPU memory first.
if [ "$FREE_VRAM" = true ] && [ "$NO_LLM" = false ]; then
    free_monailabel_vram "$ML_URL" || true
elif [ "$NO_LLM" = false ]; then
    info "Skipping VRAM release (--no-free-vram)."
fi

# ── LLM Report ───────────────────────────────────────────────
# Send the structured clinical summary to LM Studio's OpenAI-compatible
# /v1/chat/completions endpoint.  The LLM generates a formal radiology
# report based on the quantitative findings.
#
# The prompt instructs the model to produce a structured report with
# sections: CLINICAL INDICATION, TECHNIQUE, FINDINGS, IMPRESSION,
# and RECOMMENDATION.  Temperature is kept low (0.2) for factual output.
if [ "$NO_LLM" = false ]; then
    echo ""
    info "Generating radiology report via LLM at ${LLM_URL} ..."

    REPORT=$(python3 - << PYEOF
import json, sys
try:
    import urllib.request, urllib.error

    prompt = """You are an experienced radiologist reviewing an AI-assisted medical imaging analysis.
Based ONLY on the structured quantitative results below, write a formal radiology report.

STRICT RULES — follow exactly:
  * Use the 'Modality' stated in the results. Do NOT guess or change the modality.
  * Do NOT invent normal/reference ranges. Only comment on normality when the
    results give a 'Ref' range and a Flag for that structure.
  * For any structure whose Ref is '-', report the measured volume WITHOUT any
    statement about whether it is normal, high, or low.
  * Only call a value HIGH/LOW if it is explicitly flagged '⚠ HIGH' / '⚠ LOW'.
  * Do not fabricate findings that are not present in the data below.

Report format:
  CLINICAL INDICATION: (infer from model + the stated modality only)
  TECHNIQUE: (model used, stated modality)
  FINDINGS:
    - List each structure with its measured volume; note the reference range and
      flag ONLY when one is provided
    - For detection results: describe number, location, and size of findings
    - For classification: report confidence scores and positive findings
  IMPRESSION:
    - summary of the structures explicitly flagged '⚠ HIGH' or '⚠ LOW' (if none, say so)
  RECOMMENDATION: (if applicable)

=== STRUCTURED AI ANALYSIS RESULTS ===
${CLINICAL_SUMMARY}

Write the radiology report now:"""

    payload = json.dumps({
        "model": "${LLM_MODEL_NAME}",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": ${LLM_MAX_TOKENS:-2048},
        "temperature": ${LLM_TEMPERATURE:-0.2},
        "stream": False
    }).encode("utf-8")

    req = urllib.request.Request(
        "${LLM_URL}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=${LLM_TIMEOUT:-300}) as resp:
        result = json.load(resp)
        report = result["choices"][0]["message"]["content"]
        print(report)
except Exception as e:
    print(f"[LLM] Not available: {e}", file=sys.stderr)
    print("[Report generation skipped — LM Studio may not be running]")
PYEOF
)

    echo ""
    echo -e "${BOLD}${CYAN}══ Radiology Report (LLM Generated) ══${NC}"
    echo "$REPORT"
    echo ""

    # ── Auto-save report ─────────────────────────────────────
    if [ "$AUTO_SAVE_REPORT" = true ]; then
        mkdir -p "$RUN_DIR"
        {
            echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Model:     ${MODEL}"
            echo "Image:     ${IMAGE_PATH}"
            echo "LLM:       ${LLM_MODEL_NAME} @ ${LLM_URL}"
            echo "============================================================"
            echo ""
            echo "=== QUANTITATIVE FINDINGS ==="
            echo "$CLINICAL_SUMMARY"
            echo ""
            echo "=== LLM RADIOLOGY REPORT ==="
            echo "$REPORT"
        } > "${RUN_DIR}/report.txt"
        ok "Auto-saved report to:   ${RUN_DIR}/report.txt"
    fi
fi

rm -f "$TMPFILE"
