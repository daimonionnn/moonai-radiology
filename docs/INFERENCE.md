# Inference Guide

## Quick Inference via CLI

The `run-inference.sh` script handles both single files and DICOM directories automatically.
DICOM directories are uploaded via the session API so MONAI Label handles DICOM→volume conversion.

### Auto-save behaviour

Every run creates a dedicated subfolder inside `results/` and writes both files into it:

```
results/
└── YYYYMMDD_HHMMSS_<model>_<patient/dataset>/
    ├── findings.json    ← raw inference output (labels, boxes, latencies)
    └── report.txt       ← LLM radiology report + run metadata
```

The folder name is built from **DICOM tags** (PatientName, SeriesDescription, Modality, StudyDate)
when the input is a DICOM directory, or from **path components** for NIfTI files.

Opt-out flags:

| Flag | Effect |
|---|---|
| `--no-save-findings` | Skip auto-saving findings JSON |
| `--no-save-report` | Skip auto-saving LLM report |
| `--output <file>` | Save findings to explicit path instead of auto-named file |
| `--no-llm` | Skip LLM entirely (no report generated or saved) |
| `--no-free-vram` | Skip restarting monailabel to free GPU before LLM call |
| `--no-unload-llm` | Skip unloading the LLM from LM Studio before inference |

### Findings processing pipeline

MONAI Label returns a `multipart/form-data` response with two parts:

| Part | Contents |
|---|---|
| `params` | JSON: label names, detection boxes, centroids, latencies |
| `image` | Binary NIfTI segmentation mask (the actual label map) |

`scripts/inference/process_findings.py` processes both parts before the LLM sees anything:

1. **Parses** the raw multipart response
2. **Extracts original image metadata** — reads DICOM `PixelSpacing`/`SliceThickness` or NIfTI header zooms from the source data to determine the true acquisition spacing
3. **Loads** the NIfTI mask with nibabel  
4. **Counts voxels** per label → multiplies by physical voxel volume (from NIfTI header spacing) → **cm³/mL**
5. **Compares spacing** — if the output mask spacing differs from the original image spacing by >1% (due to model resampling), emits a `[WARNING]` alerting that volumes may be inaccurate
6. **Formats** detection boxes with centroid coordinates and bounding box size
7. **Formats** classification probabilities with positive/negative flags

The resulting structured table is what goes to the LLM — not raw JSON.
The raw MONAI Label params JSON is still saved in `findings.json` for downstream use.

Example output (wholeBody_ct_segmentation):
```
AI Inference Report
Model      : wholeBody_ct_segmentation
Source     : datasets/ct/<series>
Original   : size 512×512×183 vox, spacing 0.74×0.74×3.00 mm

Segmentation: 87 structures identified  (voxel size 1.20×1.20×3.00 mm, volume 512×512×183 vox)
  [WARNING] Output mask spacing (1.20×1.20×3.00) differs from original image (0.74×0.74×3.00).
            Volumes below are based on the resampled spacing, and may contain inaccuracies.

  Structure                                     Volume (cm³/mL)
  ─────────────────────────────────────────────  ────────────────
  liver                                               1482.3 cm³
  left_lung                                           1243.1 cm³
  right_lung                                          1387.4 cm³
  spleen                                               342.8 cm³
  ...

  Total segmented volume: 12345.6 cm³

Processing time: pre=2.1s  infer=11.3s  total=13.4s
```

> **Note:** The `[WARNING]` line appears when MONAI Label has resampled the input
> image to the model's training resolution (e.g. 1×1×1 mm isotropic).  The original
> acquisition spacing is extracted from the DICOM `PixelSpacing` / `SliceThickness`
> tags or the source NIfTI header.  This alerts the LLM and the reader that absolute
> volume numbers should be interpreted with caution.

### Examples

```bash
# Whole-body CT segmentation — findings + report auto-saved to results/
./scripts/inference/run-inference.sh \
    --model wholeBody_ct_segmentation \
    --image datasets/ct/<series>

# Lung nodule detection from CT
./scripts/inference/run-inference.sh \
    --model lung_nodule_ct_detection \
    --image datasets/ct/<series>

# 133-structure brain MRI segmentation (single T1 series — works with standard MRI)
./scripts/inference/run-inference.sh \
    --model wholeBrainSeg_Large_UNEST_segmentation \
    --image datasets/mri/<series>

# Brain tumor segmentation  ⚠️  Requires 4-channel BraTS-format NIfTI (see note below)
./scripts/inference/run-inference.sh \
    --model brats_mri_segmentation \
    --image datasets/mri/study_4ch.nii.gz

# Skip LLM — save only findings, no report file
./scripts/inference/run-inference.sh \
    --model lung_nodule_ct_detection \
    --image datasets/ct/<series> \
    --no-llm

# Save findings to an explicit path (auto-named report is still saved)
./scripts/inference/run-inference.sh \
    --model wholeBody_ct_segmentation \
    --image datasets/ct/<series> \
    --output results/wholebody_findings.json

# Run without saving anything (stdout only)
./scripts/inference/run-inference.sh \
    --model lung_nodule_ct_detection \
    --image datasets/ct/<series> \
    --no-save-findings --no-save-report

# List all loaded models
./scripts/inference/run-inference.sh --list-models
```

> **⚠️ `brats_mri_segmentation` — 4-channel multimodal MRI required**
>
> This model (SegResNet, BraTS 2018) expects a **single NIfTI file** where the channel dimension
> contains all 4 MRI modalities stacked: T1, T1ce (contrast), T2, T2-FLAIR (`shape: [4, H, W, D]`).
> Feeding a single DICOM series will fail with a dimension error.
> Use a pre-processed BraTS-format NIfTI, or convert with `dcm2niix` + channel stacking.
> For standard single-series MRI, use `wholeBrainSeg_Large_UNEST_segmentation` instead.

> **⚠️ GPU VRAM requirements**
>
> | Model | Min VRAM | Notes |
> |---|---|---|
> | `lung_nodule_ct_detection` | ~2 GB | Fastest, detection-only |
> | `breast_density_classification` | ~2 GB | 2D mammography only |
> | `brats_mri_segmentation` | ~4 GB | Needs 4-channel NIfTI input |
> | `prostate_mri_anatomy` | ~4 GB | MRI |
> | `pathology_tumor_detection` | ~4 GB | WSI patch images only |
> | `swin_unetr_btcv_segmentation` | ~6 GB | 13 abdominal organs |
> | `pancreas_ct_dints_segmentation` | ~6 GB | Pancreas + tumor (DiNTS) |
> | `pathology_nuclei_segmentation_classification` | ~6 GB | WSI patch images only |
> | `vista3d` | ~8 GB | Universal 3D segmentation |
> | `wholeBody_ct_segmentation` | ~9 GB | 104-structure SegResNet |
> | `wholeBrainSeg_Large_UNEST_segmentation` | ~12 GB | 133 brain structures |
>
> Only one model is loaded into GPU VRAM at a time (on-demand, `MONAILABEL_PRELOAD=false`).
> If LM Studio has a large language model loaded, it may consume most of the GPU VRAM.
> Unload the LLM before running memory-intensive segmentation models.

---

## Loaded Models

Configured in `docker/.env` via `MONAILABEL_MODELS`. All 11 downloaded bundles are currently enabled:

```
lung_nodule_ct_detection, wholeBody_ct_segmentation, brats_mri_segmentation,
swin_unetr_btcv_segmentation, pancreas_ct_dints_segmentation, breast_density_classification,
vista3d, pathology_tumor_detection, pathology_nuclei_segmentation_classification,
wholeBrainSeg_Large_UNEST_segmentation, prostate_mri_anatomy
```

All bundles are in `models/bundles/` and auto-synced to the app model directory on container startup.
Models are loaded into GPU VRAM **on-demand** (`MONAILABEL_PRELOAD=false`).

To change the active model list, edit `MONAILABEL_MODELS` in `docker/.env` then recreate the
container (a simple `restart` does not re-read env files):

```bash
docker-compose -f docker/docker-compose.yml --env-file docker/.env up -d --force-recreate monailabel
```

---

## MONAI Label REST API

### List Available Models

```bash
# Trailing slash required — MONAI Label returns 307 without it
curl -sL http://localhost:8000/info/ | python3 -c "
import json, sys
info = json.load(sys.stdin)
for name, meta in info.get('models', {}).items():
    print(f'{name:<50}  {meta.get(\"description\",\"\")[:60]}')
"
```

### Upload DICOM Series and Run Inference

DICOM directories must be uploaded via the session API (MONAI Label converts DICOM→NIfTI internally):

```bash
# Step 1: zip DICOM files from INSIDE the series directory
cd datasets/ct/<series>
zip -qr /tmp/series.zip .

# Step 2: create session with uncompress=true
SESSION=$(curl -sL -X PUT "http://localhost:8000/session/?uncompress=true" \
    -F "files=@/tmp/series.zip" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['session_id'])")

# Step 3: run inference with session_id
curl -sL -X POST \
    "http://localhost:8000/infer/wholeBody_ct_segmentation?session_id=${SESSION}" \
    -F 'params={"result_extension":".nii.gz"}' \
    | python3 -c "
import sys, re, json
content = sys.stdin.read()
m = re.search(r'name=\"params\"[^\r\n]*\r?\n(?:Content-Type:[^\r\n]*\r?\n)?\r?\n(\{.*?\})(?:\r?\n--)', content, re.DOTALL)
print(json.dumps(json.loads(m.group(1)), indent=2) if m else content[:500])
"

# Step 4: clean up session
curl -sL -X DELETE "http://localhost:8000/session/${SESSION}" > /dev/null
rm -f /tmp/series.zip
```

### Run Inference on a NIfTI File

```bash
curl -sL -X POST "http://localhost:8000/infer/lung_nodule_ct_detection" \
    -F 'params={"result_extension":".nii.gz"}' \
    -F "file=@chest_ct.nii.gz" \
    | python3 -c "
import sys, re, json
content = sys.stdin.read()
m = re.search(r'name=\"params\"[^\r\n]*\r?\n(?:Content-Type:[^\r\n]*\r?\n)?\r?\n(\{.*?\})(?:\r?\n--)', content, re.DOTALL)
print(json.dumps(json.loads(m.group(1)), indent=2) if m else content)
"
```

### Response Format

The `/infer` endpoint returns `multipart/form-data`, not plain JSON. Response parts:

| Part name | Content-Type | Contents |
|---|---|---|
| `params` | `application/json` | Findings: labels, boxes, centroids, latencies |
| `image` | `application/json` or `application/octet-stream` | Segmentation mask or annotation file |

### Run Inference by Study ID (datastore)

```bash
# List studies in local datastore
curl -sL http://localhost:8000/datastore/ | python3 -m json.tool

# Run inference on a stored study
curl -sL -X POST "http://localhost:8000/infer/lung_nodule_ct_detection?image=STUDY_ID" \
    -F 'params={}'
```

---

## Python SDK Inference

```python
import requests, re, json

ML_URL = "http://localhost:8000"

# --- Inference on a NIfTI file ---
with open("chest_ct.nii.gz", "rb") as f:
    resp = requests.post(
        f"{ML_URL}/infer/lung_nodule_ct_detection",
        files={"file": ("chest_ct.nii.gz", f, "application/octet-stream")},
        data={"params": '{"result_extension":".nii.gz"}'},
        timeout=300,
    )
resp.raise_for_status()

# Response is multipart/form-data — extract the 'params' JSON part
content = resp.text
match = re.search(
    r'name="params"[^\r\n]*\r?\n(?:Content-Type:[^\r\n]*\r?\n)?\r?\n(\{.*?\})(?:\r?\n--)',
    content, re.DOTALL
)
findings = json.loads(match.group(1)) if match else {}
print("Labels:", list(findings.get("label_names", {}).keys())[:10])
print("Latency total:", findings.get("latencies", {}).get("total"), "s")
```

```python
# --- Inference on a DICOM directory via session API ---
import requests, json, os, zipfile, io

ML_URL = "http://localhost:8000"
dicom_dir = "datasets/ct/<series>"

# Zip DICOM files from inside the directory (files must be at zip root)
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
    for fname in os.listdir(dicom_dir):
        zf.write(os.path.join(dicom_dir, fname), fname)
buf.seek(0)

# Create session — MONAI Label converts DICOM to NIfTI internally
sess = requests.put(
    f"{ML_URL}/session/",
    params={"uncompress": "true"},
    files={"files": ("series.zip", buf, "application/zip")},
)
sess.raise_for_status()
session_id = sess.json()["session_id"]

# Run inference
resp = requests.post(
    f"{ML_URL}/infer/wholeBody_ct_segmentation",
    params={"session_id": session_id},
    data={"params": '{"result_extension":".nii.gz"}'},
    timeout=300,
)
requests.delete(f"{ML_URL}/session/{session_id}")  # always clean up
resp.raise_for_status()
print(f"HTTP {resp.status_code} — inference complete")
```

Example `params` response for `lung_nodule_ct_detection` (no nodules found):

```json
{
  "name": "MONAILabel Annotations - lung_nodule_ct_detection",
  "model": "lung_nodule_ct_detection",
  "box": [],
  "label": [],
  "centroids": {},
  "latencies": { "pre": 2.46, "infer": 4.45, "total": 6.91 }
}
```

---

## Triton Inference Server (Production) — *optional, not in default stack*

> Triton was removed from the default `docker-compose.yml`. Enable it first via
> [OPTIONAL_SERVICES.md](OPTIONAL_SERVICES.md), then use the steps below.

### Export a bundle to Triton

```bash
python scripts/export_to_triton.py \
    --bundle models/bundles/wholeBody_ct_segmentation \
    --out    models/triton \
    --name   wholebody_ct_seg

# Verify model loaded (Triton HTTP is on port 8010)
curl http://localhost:8010/v2/models/wholebody_ct_seg
```

### gRPC Inference (Python)

```python
import tritonclient.grpc as grpcclient
import numpy as np

client = grpcclient.InferenceServerClient(url="localhost:8001")

input_data = np.zeros([1, 1, 240, 240, 160], dtype=np.float32)
inputs = [grpcclient.InferInput("INPUT__0", input_data.shape, "FP32")]
inputs[0].set_data_from_numpy(input_data)

outputs = [grpcclient.InferRequestedOutput("OUTPUT__0")]
result = client.infer("wholebody_ct_seg", inputs, outputs=outputs)
segmentation = result.as_numpy("OUTPUT__0")
print("Segmentation shape:", segmentation.shape)
```

### HTTP Inference (REST)

```bash
# Triton HTTP port is 8010 (host), maps to 8000 inside container
curl -X POST http://localhost:8010/v2/models/wholebody_ct_seg/infer \
    -H "Content-Type: application/json" \
    -d '{
        "inputs": [{
            "name":"INPUT__0",
            "shape":[1,1,240,240,160],
            "datatype":"FP32",
            "data": []
        }]
    }'
```

---

## MONAI Deploy — Packaging as a MAP

MONAI Deploy App SDK packages your inference pipeline as a **MONAI Application Package (MAP)** — a self-contained Docker image with DICOM I/O.

### Install SDK (host)

```bash
pip install monai-deploy-app-sdk
```

### Create an App

```python
# my_seg_app/app.py
from monai.deploy.core import Application
from monai.deploy.operators import (
    DICOMDataLoaderOperator,
    DICOMSeriesSelectorOperator,
    MonaiBundleInferenceOperator,
    DICOMSegmentationWriterOperator,
)

class WholeBodySegApp(Application):
    def compose(self):
        loader  = DICOMDataLoaderOperator()
        select  = DICOMSeriesSelectorOperator(rules='{"Modality": "CT"}')
        infer   = MonaiBundleInferenceOperator(
            bundle_path="models/bundles/wholeBody_ct_segmentation"
        )
        writer  = DICOMSegmentationWriterOperator()
        self.add_flow(loader, select)
        self.add_flow(select, infer, {"study_selected_series_list": "study_selected_series_list"})
        self.add_flow(infer, writer, {"pred": "seg_image"})

if __name__ == "__main__":
    WholeBodySegApp().run()
```

### Package and Run

```bash
monai-deploy package my_seg_app/ \
    -c my_seg_app/app.yaml \
    -t wholebody_seg_app:latest \
    --platform x86_64

mkdir -p input output
cp -r datasets/ct/<series> input/
monai-deploy run wholebody_seg_app-x64-workstation-dgpu-linux-amd64:latest \
    -i input -o output
```

---

## Downloaded Bundles

All 11 bundles are in `models/bundles/` and auto-synced to the app model directory on startup.

| Bundle | Modality | Task | Min VRAM |
|---|---|---|---|
| `lung_nodule_ct_detection` | CT | Lung nodule detection (RetinaNet, LUNA16) | ~2 GB |
| `wholeBody_ct_segmentation` | CT | 104-structure whole-body segmentation | ~9 GB |
| `brats_mri_segmentation` | MRI (**4-ch**) | Brain tumor WT/TC/ET (BraTS 2018) | ~4 GB |
| `swin_unetr_btcv_segmentation` | CT | 13 abdominal organs (SwinUNETR) | ~6 GB |
| `pancreas_ct_dints_segmentation` | CT | Pancreas + tumor (DiNTS) | ~6 GB | ⚠️ Patched for PyTorch 2.6 (`weights_only=False`) |
| `breast_density_classification` | Mammography | Breast density classification (ACR A–D) | ~2 GB |
| `vista3d` | CT/MRI | Universal interactive 3D segmentation | ~8 GB |
| `pathology_tumor_detection` | WSI pathology | Tumor patch detection | ~4 GB |
| `pathology_nuclei_segmentation_classification` | WSI pathology | Nuclei seg + classification (HoVerNet) | ~6 GB |
| `wholeBrainSeg_Large_UNEST_segmentation` | MRI | 133 brain structures (UNesT) | ~12 GB |
| `prostate_mri_anatomy` | MRI | Prostate anatomy segmentation | ~4 GB |
