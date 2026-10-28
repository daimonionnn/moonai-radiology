# MOONAI Radiology — documentation

A self-hosted, GPU-accelerated medical imaging AI platform based on the MONAI ecosystem.  
Supports **MRI, CT, X-ray (RTG), Mammography, and Pathology** data from annotation through training to automated diagnosis.

## Hardware

Reference hardware (what the project is developed and tested on):

| Component | Spec |
|---|---|
| GPU | NVIDIA RTX PRO 6000 Blackwell (96 GB VRAM, sm_120) |
| RAM | 256 GB system RAM |
| OS | Ubuntu 22.04+ (reference host: 26.04) |
| CUDA | 12.8+ (required for Blackwell) |
| Driver | ≥ 570 |

With 96 GB VRAM everything runs on one GPU at the same time: the MONAI / TotalSegmentator
imaging models and a local report LLM (e.g. a 27–32B model at Q8).

> **Smaller GPU:** a 32 GB card such as the RTX 5090 (the original development GPU) is
> most likely still enough for the imaging pipeline itself. Run the report LLM on
> another machine instead (e.g. an AMD Strix Halo box with 128 GB unified memory) and
> point `LLM_BASE_URL` in `docker/.env` at it. No GPU at all: see the CPU path in the
> root [README](../README.md).

---

## Quick Start (3 commands)

```bash
# 1. Initial setup — installs prerequisites, pulls images, builds custom container
./scripts/setup.sh

# 2. Download pretrained MONAI Zoo models
./scripts/download-models.sh

# 3. Start the full platform
./scripts/start.sh
```

---

## Services

| Service | URL | Purpose |
|---|---|---|
| **MONAI Label** | http://localhost:8000 | Annotation + active-learning server |
| **MONAI Label Swagger** | http://localhost:8000/docs | REST API documentation |
| **OHIF Viewer** | http://localhost:3000 | Browser DICOM viewer |
| **Orthanc DICOM** | http://localhost:8042 | DICOM store (DICOMweb) |
| **TensorBoard** | http://localhost:6006 | Training monitoring |
| **LM Studio LLM** | http://localhost:1234 | Radiology report generation |

3D Slicer runs **natively on the host** — connect it to MONAI Label at `http://localhost:8000`.

> **Triton** (production serving) and **Holoscan** (real-time streaming) are not
> in the default stack — see [OPTIONAL_SERVICES.md](OPTIONAL_SERVICES.md) to add them.

---

## Pretrained Models (MONAI Zoo)

| Model | Modality | Task |
|---|---|---|
| `brats_mri_segmentation` | MRI | Brain tumor (WT/TC/ET) |
| `lung_nodule_ct_detection` | CT | Lung nodule detection |
| `wholeBody_ct_segmentation` | CT | 104-structure whole-body |
| `swin_unetr_btcv_segmentation` | CT | 13 abdominal organs |
| `pancreas_ct_dints_segmentation` | CT | Pancreas + tumor |
| `vista3d` | CT/MRI | Universal interactive 3D seg |
| `breast_density_classification` | Mammography | Breast density ACR A-D |
| `pathology_tumor_detection` | WSI Pathology | Tumor patch detection |
| `pathology_nuclei_segmentation_classification` | WSI Pathology | Nuclei seg + class |
| `wholeBrainSeg_Large_UNEST_segmentation` | MRI | 133 brain structures |
| `prostate_mri_anatomy` | MRI | Prostate zones |
| `cxr_pathology` *(TorchXRayVision)* | X-ray / RTG | 14 CXR pathologies |

---

## Directory Structure

```
monai/
├── docker/                    ← Docker Compose + configs
│   ├── docker-compose.yml
│   ├── .env                   ← your local config (gitignored)
│   ├── .env.example           ← template
│   ├── monailabel/            ← custom CUDA 12.8 image
│   │   ├── Dockerfile
│   │   ├── entrypoint.sh
│   │   └── xrayvision_infer.py
│   ├── ohif/
│   │   └── app-config.js
│   └── orthanc/
│       └── orthanc.json
├── apps/                      ← MONAI Label apps (auto-downloaded)
├── datasets/
│   ├── ct/                    ← CT DICOM / NIfTI data
│   ├── mri/                   ← MRI DICOM / NIfTI data
│   ├── nifti/                 ← NIfTI-only datasets
│   ├── xray/                  ← X-ray / RTG images
│   ├── mammography/           ← Mammography DICOM
│   └── pathology/             ← WSI / pathology slides
├── models/
│   ├── bundles/               ← Downloaded MONAI Zoo bundles
│   └── triton/                ← Triton model repository
├── scripts/                   ← Management scripts
├── storage/
│   ├── orthanc-db/            ← Orthanc DICOM database
│   ├── logs/                  ← Container logs
│   └── tensorboard/           ← Training metrics
└── docs/                      ← Documentation
```

---

## Documentation

| Document | Contents |
|---|---|
| [SETUP.md](SETUP.md) | Prerequisites, installation, 3D Slicer plugin |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Component diagram, data flow |
| [LABELING.md](LABELING.md) | Annotation workflows (3D Slicer, OHIF) |
| [TRAINING.md](TRAINING.md) | Fine-tuning, custom training, TensorBoard |
| [INFERENCE.md](INFERENCE.md) | Running inference, MONAI Deploy, Triton |
| [LLM_INTEGRATION.md](LLM_INTEGRATION.md) | LM Studio radiology report generation |
| [VESSEL_ANALYSIS.md](VESSEL_ANALYSIS.md) | Renal artery / vessel analysis: TotalSegmentator + vesselFM + 3D Slicer VMTK |
| [PROJECT_RATIONALE.md](PROJECT_RATIONALE.md) | Why this project, does it make sense, alternatives, regulation |
| [RADIOLOGIST_SUMMARY.md](RADIOLOGIST_SUMMARY.md) | Project summary for a cooperating radiologist ([Slovak original](SK/SUMAR_PRE_RADIOLOGA.md)) |
| [research/BETTER_MODELS.md](research/BETTER_MODELS.md) | Survey of better open/commercial models, oncology focus (Oct 2026) |
| [REVIEW_AND_TODO.md](REVIEW_AND_TODO.md) | Known issues, security prep, roadmap |
| [history/INITIAL_PLAN.md](history/INITIAL_PLAN.md) | Original project brief and plan (historical) |

---

## Management Scripts

```bash
./scripts/setup.sh              # First-time setup
./scripts/build.sh              # Rebuild custom Docker image
./scripts/download-models.sh    # Download MONAI Zoo bundles
./scripts/start.sh              # Start all services
./scripts/stop.sh               # Stop all services
./scripts/restart.sh [service]  # Restart (all or one service)
./scripts/status.sh             # Health check + GPU status
./scripts/logs.sh [service]     # Tail logs
./scripts/switch-app.sh <app>   # Switch MONAI Label app
./scripts/install-slicer.sh     # Install 3D Slicer on host
./scripts/inference/run-inference.sh      # CLI inference + LLM report
python scripts/inference/process_findings.py   # Post-process inference findings (volumes, spacing)
python scripts/inference/report_generator.py   # Python LLM report generator
python scripts/export_to_triton.py   # Export bundle to Triton
```

Key `run-inference.sh` flags: `--model`, `--image`, `--no-llm`, `--no-free-vram`,
`--no-unload-llm`, `--no-save-findings`, `--no-save-report`, `--output`, `--list-models`.
