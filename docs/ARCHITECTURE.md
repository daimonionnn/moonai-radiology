# Architecture — MONAI Medical Imaging Platform

## Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│               Host  (Ubuntu + RTX PRO 6000, 96 GB)              │
│                                                                  │
│  ┌──────────────────┐   ┌─────────────────────────────────────┐ │
│  │   3D Slicer       │   │  Web Browser                        │ │
│  │   (native host)   │   │                                     │ │
│  │   MONAI Label     │   │  ┌──────────────┐ ┌─────────────┐  │ │
│  │   plugin          │   │  │  OHIF Viewer │ │  TensorBoard│  │ │
│  └────────┬──────────┘   │  │  :3000       │ │  :6006      │  │ │
│           │              │  └──────┬───────┘ └─────────────┘  │ │
│           │ HTTP :8000   │         │ DICOMweb                  │ │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ┼ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │ │
│           │     DOCKER   │         │                            │ │
│  ┌────────▼──────────────▼─────────▼────────────────────────┐  │ │
│  │              MONAI Label Server  :8000                    │  │ │
│  │   Image: monai-platform/monailabel  (CUDA 12.8)           │  │ │
│  │                                                            │  │ │
│  │   Apps:    monaibundle | radiology | pathology             │  │ │
│  │   Models:  MONAI Zoo bundles (brats, lung, vista3d …)     │  │ │
│  │            TorchXRayVision (CXR/RTG, 14 pathologies)      │  │ │
│  │   Storage: ./datasets  ./models/bundles                    │  │ │
│  └─────────────────────┬──────────────────────────────────── ┘  │ │
│                        │ DICOMweb                                │ │
│  ┌─────────────────────▼──────────────────────────────────────┐ │ │
│  │              Orthanc DICOM Server  :8042 / :4242            │ │ │
│  │   DICOM AET: MONAI    DICOMweb: /dicom-web                  │ │ │
│  │   Storage: ./storage/orthanc-db                             │ │ │
│  └────────────────────────────────────────────────────────────┘ │ │
│                                                                  │ │
│  ┌───────────────────────────┐  ┌────────────────────────────┐  │ │
│  │  Triton Inference Server  │  │  NVIDIA Holoscan           │  │ │
│  │  :8010(HTTP) :8001(gRPC)  │  │  no web UI (dev container)│  │ │
│  │  Models: ./models/triton  │  │  docker exec -it holoscan  │  │ │
│  └───────────────────────────┘  └────────────────────────────┘  │ │
│                                                                  │ │
│  ┌──────────────────────────────────────────────────────────┐   │ │
│  │  LLM server (LM Studio etc., LLM_BASE_URL, e.g. :1234)   │   │ │
│  │  OpenAI-compatible API  →  Radiology report generation   │   │ │
│  └──────────────────────────────────────────────────────────┘   │ │
└─────────────────────────────────────────────────────────────────┘ │
```

---

## Data Flow: Annotation → Training → Inference → Report

```
1. INGEST
   Patient DICOM/NIfTI files
       │
       ├─ DICOM → upload to Orthanc (C-STORE / web upload / drag-drop)
       └─ NIfTI → place in ./datasets/nifti/  or  ./datasets/<modality>/

2. ANNOTATION  (human-in-the-loop)
   3D Slicer / OHIF → connects to MONAI Label :8000
       │
       ├─ Active Learning:  GET /activelearning/random  → next unlabeled sample
       ├─ AI Pre-label:     POST /infer/<model>         → AI segmentation
       ├─ Human Edit:       user refines in Slicer Segment Editor
       └─ Save Label:       PUT /label/<image_id>       → stored in datastore

3. TRAINING
   POST /train/<model>  (triggers fine-tuning on labeled data)
       │
       ├─ MONAI Label trains in background using labeled pairs
       ├─ Progress + metrics → ./storage/tensorboard/
       ├─ Monitor: http://localhost:6006
       └─ Best checkpoint saved → ./apps/<app>/model/<model>/best_model.pt

4. INFERENCE
   unload_llm_vram()  →  POST /api/v1/models/unload (free GPU for model)
       │
   POST /infer/<model>?image=<id>  OR  file upload
       │
       ├─ MONAI Label returns segmentation mask (.nii.gz) + params JSON
       ├─ CXR/RTG: TorchXRayVision returns 14-class probability dict
       ├─ process_findings.py extracts original spacing (DICOM/NIfTI)
       │    └─ [WARNING] if output spacing ≠ original spacing (>1% diff)
       └─ Result displayed in 3D Slicer / OHIF

5. PRODUCTION DEPLOYMENT  (optional)
   python scripts/export_to_triton.py  →  models/triton/<model>/
       │
       └─ Triton auto-polls → model live at :8010 (HTTP REST) / :8001 (gRPC)

6. LLM REPORT GENERATION
   free_monailabel_vram()  →  docker restart (free GPU for LLM)
       │
   Inference JSON findings
       │
       └─ scripts/inference/report_generator.py  →  LM Studio :1234
              POST /v1/chat/completions
              prompt = modality-specific template + findings
              → Structured radiology report text
```

---

## Docker Network

All containers share the `monai-platform` bridge network.  
Inter-container hostname resolution:

| Container | Hostname | Internal port |
|---|---|---|
| MONAI Label | `monailabel` | 8000 |
| Orthanc | `orthanc` | 8042 / 4242 |
| OHIF | `ohif` | 80 |
| TensorBoard | `tensorboard` | 6006 |
| Triton *(optional)* | `triton` | 8000 (HTTP) / 8001 (gRPC) / 8002 (metrics) — see [OPTIONAL_SERVICES.md](OPTIONAL_SERVICES.md) |
| Holoscan *(optional)* | `holoscan` | 8008 — see [OPTIONAL_SERVICES.md](OPTIONAL_SERVICES.md) |

> **Note:** Triton and Holoscan below/above are shown for reference but are **not
> in the default `docker-compose.yml`** — the diagrams predate their removal. Add
> them back via [OPTIONAL_SERVICES.md](OPTIONAL_SERVICES.md) when needed.

MONAI Label running in `dicomweb` mode connects to Orthanc as:
`http://orthanc:8042/dicom-web`

---

## GPU Allocation

All containers with GPU access use `NVIDIA_VISIBLE_DEVICES=all`.  
For multi-GPU setups, set `CUDA_VISIBLE_DEVICES=0` (MONAI Label) and  
`CUDA_VISIBLE_DEVICES=1` (Triton) in `docker/.env` to pin them.

---

## MONAI Stack Relationship

```
MONAI Core          — transforms, networks, losses, metrics, training loops
  ↑  used by
MONAI Label         — interactive annotation server, active learning, REST API
  ↑  models from
MONAI Model Zoo     — pretrained .zip bundles (GitHub / HuggingFace)
  ↑  consumed by
MONAI Deploy SDK    — packages inference pipelines as MAP Docker images
  ↑  powered by
NVIDIA Holoscan SDK — real-time streaming DAG execution engine
```
