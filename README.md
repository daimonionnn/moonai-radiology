# MOONAI Radiology

**M**edical (not only for) **O**ncology **O**pen **N**etwork For **AI** — a self-hosted
platform for experimenting with **AI-assisted analysis of radiology images** (CT, MRI,
X-ray, mammography, digital pathology), built on the open-source
[MONAI](https://monai.io/) ecosystem. It wires together annotation, pretrained model
inference, a DICOM store and viewer, and an LLM that drafts a human-readable report from
the quantitative findings.

The goal is to **assist radiologists, not replace them** — a fast "second pair of eyes"
(organ volumetry, candidate lesions, structured drafts) that a physician reviews and
signs off.

> ⚠️ **Not a medical device. Research and educational use only.**
> Outputs are experimental and can be inaccurate. Nothing here is validated,
> CE/FDA-cleared, or fit for clinical decision-making. Do not use it to diagnose, treat,
> or make decisions about real patients.

**Status:** 🚧 proof of concept. The full stack runs end-to-end; volumetry agrees with
TotalSegmentator, reference flags are computed in code with cited sources. Next: oncology
lesion models — see [TODO](docs/TODO.md). Contributions welcome.

---

## What's in the box

| Component | Role |
|---|---|
| **MONAI Label** | Annotation + serves MONAI Zoo model inference (REST API) |
| **MONAI Zoo bundles** | 11 pretrained models (see below) |
| **Orthanc** | DICOM store + DICOMweb |
| **OHIF Viewer** | Browser-based DICOM viewer |
| **3D Slicer** (host) | Desktop viewer and annotation, connects to MONAI Label |
| **TotalSegmentator** | Second CT/MR segmentation engine (comparison, bone/bowel removal) |
| **VISTA3D tumour classes** | Automatic CT tumour candidates (lung, liver, pancreas, colon, bone) — [ONCOLOGY](docs/ONCOLOGY.md) |
| **ULS+** | Click-to-measure any CT lesion (volume, RECIST axes) — [ONCOLOGY](docs/ONCOLOGY.md) |
| **nnInteractive** | Interactive 3D outlining in 3D Slicer (points, boxes, scribbles) — [ONCOLOGY](docs/ONCOLOGY.md) |
| **vesselFM** | Zero-shot 3D vessel segmentation (renal arteries) — [VESSEL_ANALYSIS](docs/VESSEL_ANALYSIS.md) |
| **LLM** (any OpenAI-compatible server, local or cloud) | Drafts the report from the computed findings, optionally in several languages |
| Shell scripts | Platform lifecycle and per-examination analyses — [scripts/README](scripts/README.md) |

### Pretrained models (MONAI Zoo)

| Model | Modality | Task |
|---|---|---|
| `wholeBody_ct_segmentation` | CT | 104 structures, whole body |
| `swin_unetr_btcv_segmentation` | CT | 13 abdominal organs |
| `pancreas_ct_dints_segmentation` | CT | Pancreas + tumour (GPU only) |
| `vista3d` | CT | Universal interactive 3D segmentation |
| `lung_nodule_ct_detection` | CT | Lung nodule detection |
| `brats_mri_segmentation` | MRI | Brain tumour (WT/TC/ET) |
| `wholeBrainSeg_Large_UNEST_segmentation` | MRI | 133 brain structures |
| `prostate_mri_anatomy` | MRI | Prostate zones |
| `breast_density_classification` | Mammography | Breast density ACR A–D |
| `pathology_tumor_detection` | WSI | Tumour patch detection |
| `pathology_nuclei_segmentation_classification` | WSI | Nuclei segmentation + class |

MONAI Label also serves `sam_2d` / `sam_3d` (Segment Anything) for interactive labeling.
Better and oncology-specific models planned next: [TODO](docs/TODO.md) P1/P2.

---

## Requirements

- Linux + Docker (Compose v2)
- **GPU** (recommended): NVIDIA GPU, driver ≥ 570, NVIDIA Container Toolkit; the custom
  image targets CUDA 12.8 / Blackwell.
- **CPU**: no GPU needed — works, just slower (see *CPU mode*).
- Optional: an OpenAI-compatible LLM server (LM Studio, llama-server, vLLM, Ollama) or a
  cloud API for the report.

Reference hardware (what the project is developed and tested on):

| Component | Spec |
|---|---|
| GPU | NVIDIA RTX PRO 6000 Blackwell, 96 GB VRAM (sm_120) |
| RAM | 256 GB |
| OS | Ubuntu 22.04+ (reference host: 26.04) |

With 96 GB everything runs on one GPU at once: the imaging models and a local report LLM
(e.g. a 27–32B model at Q8). A **32 GB card** (e.g. RTX 5090) is most likely enough for
the imaging pipeline if the LLM runs on another machine (e.g. an AMD Strix Halo with
128 GB unified memory) — point `LLM_BASE_URL` at it.

## Quick start

```bash
cp docker/.env.example docker/.env     # then set at least ORTHANC_PASSWORD (see Configuration)
./scripts/setup.sh                     # checks, host Python venv, pull/build images
./scripts/download-models.sh           # MONAI Zoo bundles
./scripts/start.sh                     # start the stack
./scripts/inference/run-inference.sh --list-models
./scripts/inference/run-inference.sh --model wholeBody_ct_segmentation --image datasets/ct/<series>
```

Results (volumes with reference flags, LLM report) are saved under `results/`
(git-ignored). Detailed installation incl. 3D Slicer: [SETUP](docs/SETUP.md).

### Services

| Service | URL | Purpose |
|---|---|---|
| MONAI Label | http://localhost:8000 (API docs `/docs`) | Inference + annotation server |
| OHIF Viewer | http://localhost:3000 | Browser DICOM viewer |
| Orthanc | http://localhost:8042 | DICOM store (login: `admin` / `ORTHANC_PASSWORD`) |
| TensorBoard | http://localhost:6006 | Training monitoring |
| LLM | `LLM_BASE_URL` in `docker/.env` | Report drafting |

3D Slicer runs **natively on the host** (`./scripts/install-slicer.sh`) and connects to
MONAI Label at `http://localhost:8000`. Triton (production serving) and Holoscan
(streaming) are not in the default stack — see [OPTIONAL_SERVICES](docs/OPTIONAL_SERVICES.md).

### CPU mode

```ini
# docker/.env
MOONAI_DEVICE=auto   # gpu if an NVIDIA GPU + Docker NVIDIA runtime are found, else cpu
# MOONAI_DEVICE=cpu  # force CPU (no NVIDIA driver/toolkit needed)
# MOONAI_DEVICE=gpu  # force GPU
```

`setup.sh`, `start.sh`, `restart.sh` and `logs.sh` then pick `docker/docker-compose.yml`
or `docker/docker-compose.cpu.yml`, and TotalSegmentator / vesselFM run on the same
device. On the reference host `wholeBody_ct_segmentation` took 50 s on CPU vs 2 s on GPU;
large models (brain transformer) take tens of minutes. One-off:
`MOONAI_DEVICE=cpu ./scripts/start.sh`. In CPU mode `pancreas_ct_dints_segmentation` is
skipped — the bundle hard-codes a CUDA device and would stop MONAI Label from starting.

## Configuration

All settings live in `docker/.env` (copy of `docker/.env.example`, git-ignored):

```ini
ORTHANC_PASSWORD=<your-own-password>     # required — start.sh refuses 'change_me'
MONAILABEL_MODELS=wholeBody_ct_segmentation,lung_nodule_ct_detection,...
MOONAI_DEVICE=auto                       # gpu | cpu | auto

LLM_BASE_URL=http://localhost:1234       # local server, or a cloud API root
LLM_MODEL=<model name as the server reports it>
LLM_API_KEY=                             # cloud APIs only
LLM_REASONING_EFFORT=none                # thinking models: no reasoning for the report
LLM_REPORT_LANGUAGES=en                  # e.g. sk or en,sk — translations are number-checked
LLM_PROMPT_DIR=config/prompts            # editable prompts and glossary
```

`docker/.env` is the **only** place for credentials: Orthanc gets them from the
environment and the OHIF proxy adds them server-side, so no tracked file and nothing sent
to the browser contains a password. Patient-identifying lines are removed before any LLM
call; with a cloud LLM the de-identified findings still leave your network — check the
data-protection rules first ([LLM_INTEGRATION](docs/LLM_INTEGRATION.md)).

## Project layout

```
moonai-radiology/
├── config/prompts/     LLM report prompts + glossary (editable text)
├── docker/             compose files (GPU, CPU), .env(.example), MONAI Label image, OHIF, Orthanc
├── scripts/            platform scripts; inference/, vessels/, lib/  → scripts/README.md
├── docs/               documentation (below); SK/ Slovak documents; research/; history/
├── apps/               MONAI Label apps (downloaded)            ┐
├── models/bundles/     MONAI Zoo bundles (downloaded)           │
├── datasets/           ct, mri, xray, mammography, pathology… │ git-ignored —
├── storage/            Orthanc database, logs, TensorBoard      │ never patient data in git
└── results/            analysis outputs                         ┘
```

## Documentation

| Document | Contents |
|---|---|
| [SETUP](docs/SETUP.md) | Prerequisites, installation, 3D Slicer + MONAI Label plugin, DICOM upload |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | Component diagram, data flow |
| [INFERENCE](docs/INFERENCE.md) | Running inference, outputs, MONAI Deploy, Triton |
| [LLM_INTEGRATION](docs/LLM_INTEGRATION.md) | Report pipeline, languages, prompts, local vs cloud LLM |
| [ONCOLOGY](docs/ONCOLOGY.md) | Click-to-measure any CT lesion (ULS+): volume, RECIST axes |
| [VESSEL_ANALYSIS](docs/VESSEL_ANALYSIS.md) | Renal arteries: TotalSegmentator + vesselFM + 3D Slicer VMTK |
| [LABELING](docs/LABELING.md) | Annotation workflows (3D Slicer, OHIF) |
| [TRAINING](docs/TRAINING.md) | Fine-tuning, custom training, TensorBoard |
| [OPTIONAL_SERVICES](docs/OPTIONAL_SERVICES.md) | Triton, Holoscan |
| [EXAMPLES](docs/EXAMPLES.md) | Anonymized CT and brain MRI reports, screenshots (OHIF, 3D Slicer) |
| [TODO](docs/TODO.md) | Prioritized open work (oncology models first) and what is done |
| [PROJECT_RATIONALE](docs/PROJECT_RATIONALE.md) | Why this project, alternatives, regulation (MDR, AI Act, GDPR) |
| [RADIOLOGIST_SUMMARY](docs/RADIOLOGIST_SUMMARY.md) | Summary for a cooperating radiologist ([Slovak original](docs/SK/SUMAR_PRE_RADIOLOGA.md)) |
| [research/PUBLIC_DATA_TESTS](docs/research/PUBLIC_DATA_TESTS.md) | Models tested on public tumour cases (LIDC, CRLM, KiTS) |
| [research/BETTER_MODELS](docs/research/BETTER_MODELS.md) | Survey of better open/commercial models, oncology focus (Oct 2026) |
| [history/INITIAL_PLAN](docs/history/INITIAL_PLAN.md) | Original brief and plan (historical) |

## License & data

Code: [Apache-2.0](LICENSE). Not affiliated with or endorsed by Project MONAI; MOONAI
builds on it. Third-party models keep their own licences — several (e.g. vesselFM,
nnInteractive weights) are **non-commercial / research only**; see [TODO](docs/TODO.md).
**Never commit patient data** — `datasets/`, `storage/` and `results/` are git-ignored
by design.
