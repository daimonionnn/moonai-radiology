# LLM Integration — Radiology Report Generation

## Overview

MONAI inference produces **structured JSON findings** (segmentation masks, detection boxes, pathology probabilities).  
The LLM integration layer translates these findings into **professional radiology reports** by calling  
your **LM Studio** instance at `http://localhost:1234` via its OpenAI-compatible API.

## Current report pipeline (run-inference.sh)

`run-inference.sh` calls [`scripts/inference/llm_report.py`](../scripts/inference/llm_report.py),
configured in `docker/.env`:

| Setting | Meaning |
|---|---|
| `LLM_BASE_URL`, `LLM_MODEL`, `LLM_API_KEY` | Any OpenAI-compatible server — local (LM Studio, llama-server, vLLM) or cloud (key needed) |
| `LLM_REASONING_EFFORT` | `none` turns reasoning off for thinking models |
| `LLM_REPORT_LANGUAGES` | `en`, `sk`, `en,sk`, … — drafted in English, translated, numbers checked |
| `LLM_PROMPT_DIR` | Prompt set (default [`config/prompts`](../config/prompts/README.md)): `report.md`, `translate.md`, `glossary.json` |

Patient-identifying lines (file paths, names) are removed before any LLM call.
Each `report.txt` records the prompt set and file hashes it was made with.
The sections below describe the older standalone `report_generator.py`.

---

## LM Studio Setup

1. Download LM Studio: https://lmstudio.ai
2. Download a suitable model. Recommended for medical report writing:
   - **Qwen 2.5 27B Instruct** (current default — strong structured output)
   - **Llama 3.1 8B Instruct** (fast, lower VRAM, good for quick reports)
   - **Llama 3.1 70B Instruct** (highest quality, requires large VRAM)
   - **Meditron-7B** (medical domain fine-tuned)
3. In LM Studio: **Local Server** → **Start Server** → port `1234`
4. Note the model identifier shown (e.g. `llama-3.1-8b-instruct`) — set in `docker/.env`

**Set in `docker/.env`:**
```bash
LLM_BASE_URL=http://localhost:1234
LLM_MODEL=qwen3.5-27b
LLM_TIMEOUT=300          # seconds — increase for slow/remote LM Studio
LLM_MAX_TOKENS=200000
LLM_TEMPERATURE=0.2
```

---

## Usage

### Command-line (with inference)

```bash
# Run inference + LLM report — a run folder is auto-created under results/
./scripts/inference/run-inference.sh \
    --model wholeBrainSeg_Large_UNEST_segmentation \
    --image datasets/mri/<series>
# → results/20260309_143022_wholeBrainSeg_Large_UNEST_segmentation_<patient>/
#       findings.json
#       report.txt

# Skip LLM — only findings JSON is auto-saved (no report file)
./scripts/inference/run-inference.sh \
    --model wholeBody_ct_segmentation \
    --image datasets/ct/<series> \
    --no-llm

# Override findings path (auto-named LLM report is still saved)
./scripts/inference/run-inference.sh \
    --model wholeBrainSeg_Large_UNEST_segmentation \
    --image datasets/mri/<series> \
    --output results/brain_findings.json

# Run with no file output at all (stdout only)
./scripts/inference/run-inference.sh \
    --model lung_nodule_ct_detection \
    --image datasets/ct/<series> \
    --no-save-findings --no-save-report

# Override timeout per-run (useful when LM Studio is on a slow remote machine)
LLM_TIMEOUT=600 ./scripts/inference/run-inference.sh \
    --model wholeBrainSeg_Large_UNEST_segmentation \
    --image datasets/mri/<series>
```

Auto-saved report header example:
```
Generated: 2026-03-09 14:30:22
Model:     wholeBrainSeg_Large_UNEST_segmentation
Image:     datasets/mri/<patient_series>/DICOM/00000001/00000016
LLM:       qwen3 @ http://127.0.0.1:8081
------------------------------------------------------------

[LLM radiology report text...]
```

> **⚠️ `brats_mri_segmentation` requires 4-channel BraTS-format NIfTI** (T1/T1ce/T2/FLAIR stacked).
> Standard single-series MRI DICOM will fail with a dimension error — use
> `wholeBrainSeg_Large_UNEST_segmentation` for single-series brain MRI instead.

### Python — from saved findings JSON

```bash
# Inference auto-saves findings JSON; pass that file to the report generator
./scripts/inference/run-inference.sh \
    --model lung_nodule_ct_detection \
    --image datasets/ct/<series> \
    --no-llm
# → results/YYYYMMDD_HHMMSS_lung_nodule_ct_detection_<patient>_findings.json

# Then generate report from saved findings
python scripts/inference/report_generator.py --findings results/<findings_file>.json
```

### Python — full pipeline

```bash
python scripts/inference/report_generator.py \
    --model wholeBrainSeg_Large_UNEST_segmentation \
    --image datasets/mri/<series> \
    --out results/brain_report.txt
```

### Python — pipe from curl

```bash
curl -sL -X POST "http://localhost:8000/infer/lung_nodule_ct_detection" \
    -F "file=@chest_ct.nii.gz" \
    | python scripts/inference/report_generator.py --stdin --model lung_nodule_ct_detection
```

---

## Example Output

**Input:** CXR pathology findings with Pneumonia=0.68, Effusion=0.71, Consolidation=0.55

**Generated report:**

```
══ Radiology Report (LLM Generated) ══

TECHNIQUE:
Posteroanterior chest radiograph. AI analysis performed using DenseNet-121
(TorchXRayVision, trained on multiple chest X-ray datasets).

FINDINGS:
- PLEURAL EFFUSION: High confidence (0.71). Blunting of the right costophrenic
  angle consistent with moderate pleural effusion.
- PNEUMONIA: High confidence (0.68). Patchy airspace opacity in the right lower
  lobe consistent with pneumonic consolidation.
- CONSOLIDATION: Moderate-high confidence (0.55). Confluent airspace disease
  in the right lower lobe.
- Cardiomegaly: Low confidence (0.08) — within normal limits.
- No pneumothorax detected (0.02).

IMPRESSION:
Right lower lobe pneumonia with associated pleural effusion. The pattern is
most consistent with bacterial pneumonia (e.g. Streptococcus pneumoniae).
COVID-19 or viral atypical pneumonia should be considered in the appropriate
clinical context.

RECOMMENDATION:
1. Correlate with clinical symptoms (fever, cough, SpO2) and laboratory results
   (CRP, WBC, procalcitonin).
2. Consider sputum culture and sensitivity.
3. Initiate appropriate antibiotic therapy per local guidelines.
4. Repeat chest X-ray in 4–6 weeks to confirm resolution.
5. If no clinical improvement in 48–72 hours, consider CT thorax for further
   characterization.
```

---

## Modality-Specific Report Templates

The `report_generator.py` uses tailored prompts per model:

| Model | Template focus |
|---|---|
| `brats_mri_segmentation` | Neuroradiology — tumor location, WT/TC/ET regions, grade, oncology referral |
| `lung_nodule_ct_detection` | Thoracic radiology — Fleischner Society classification, follow-up interval |
| `wholeBody_ct_segmentation` | Multi-organ — 104-structure summary, incidental findings, prioritisation |
| `swin_unetr_btcv_segmentation` | Abdominal radiology — 13 abdominal organs, volume/attenuation |
| `pancreas_ct_dints_segmentation` | Pancreatic radiology — lesion characterisation, PDAC risk |
| `prostate_mri_anatomy` | Prostate MRI — zonal anatomy, PI-RADS guidance |
| `wholeBrainSeg_Large_UNEST_segmentation` | Neuroradiology — 133 brain structures, volumetry |
| `breast_density_classification` | Breast imaging — ACR density A–D, supplemental screening recommendation |
| `pathology_tumor_detection` | Pathology — WSI tumor extent, IHC recommendations, MDT referral |
| `default` | Generic structured report for any other model |

---

## Direct API Call

```python
import httpx, json, os

LLM_URL   = os.getenv("LLM_BASE_URL",  "http://localhost:1234")
LLM_MODEL = os.getenv("LLM_MODEL",      "qwen3.5-27b")

findings_summary = """
Lung nodule detected:
  - Right upper lobe, 8mm solid nodule
  - Confidence: 0.87
  - Spiculated margins
"""

prompt = f"""You are a thoracic radiologist.
Generate a structured report for this CT finding:
{findings_summary}
Include: Technique, Findings, Impression, Fleischner recommendation."""

payload = {
    "model": LLM_MODEL,
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": 1024,
    "temperature": 0.2,
    "stream": False,
}

with httpx.Client(timeout=int(os.getenv("LLM_TIMEOUT", 300))) as client:
    resp = client.post(f"{LLM_URL}/v1/chat/completions", json=payload)
    resp.raise_for_status()
    report = resp.json()["choices"][0]["message"]["content"]

print(report)
```

---

## LLM Connectivity Verification

```bash
# Check LM Studio is reachable
curl http://localhost:1234/v1/models | python3 -m json.tool

# Quick test
curl http://localhost:1234/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "qwen3.5-27b",
        "messages": [{"role":"user","content":"Say: LM Studio is working."}],
        "max_tokens": 20
    }'
```

---

## Architecture: MONAI → LLM Pipeline

```
DICOM / NIfTI Image
        │
        ▼
unload_llm_vram()  (POST /api/v1/models/unload — frees GPU for inference)
        │
        ▼
POST /infer/<model>  (MONAI Label :8000)
        │
        ▼
Inference JSON findings + spacing comparison
   {predictions: {...}, findings: [...], abnormal: true}
   + original spacing vs output spacing validation
        │
        ▼
free_monailabel_vram()  (docker restart — frees GPU for LLM)
        │
        ▼
report_generator.py
   extract_findings_summary()
   load modality template
        │
        ▼
POST /v1/chat/completions  (LM Studio localhost:1234)
   model: qwen3.5-27b
   prompt: template + findings
        │
        ▼
Structured Radiology Report (text)
   → stdout  OR  --out report.txt
```

---

## GPU VRAM Management

A single GPU is shared between the segmentation models (MONAI Label) and the LLM (LM Studio).
`run-inference.sh` orchestrates VRAM automatically:

1. **Before inference** — `unload_llm_vram()` calls `POST /api/v1/models/unload` to evict
   the LLM from GPU memory, making room for the segmentation model.
2. **After inference** — `free_monailabel_vram()` restarts the MONAI Label container to
   release GPU memory, allowing LM Studio to reload the LLM.

Both steps can be suppressed with CLI flags:

| Flag | Effect |
|------|--------|
| `--no-unload-llm` | Skip step 1 — keep the LLM loaded during inference |
| `--no-free-vram`  | Skip step 2 — keep MONAI Label loaded during LLM call |

> If you have enough VRAM to keep both loaded simultaneously (e.g. 48 GB+),
> use both flags to avoid the reload overhead.

---

## Notes

- Reports are **AI-generated** and must be reviewed by a qualified radiologist before clinical use.
- Lower `LLM_TEMPERATURE` (0.1–0.2) produces more consistent, formal reports.
- For faster responses, use a smaller model (7B–8B). For higher quality diagnostic language, use 70B.
- The `report_generator.py` falls back gracefully if LM Studio is offline — it prints the raw findings summary instead.
