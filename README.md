# MOONAI Radiology

**M**edical (not only for) **O**ncology **O**pen **N**etwork For **AI** — a self-hosted platform for experimenting with **AI-assisted analysis of radiology images**
(MRI, CT, X-ray, mammography, digital pathology) built on the open-source
[MONAI](https://monai.io/) ecosystem. It wires together annotation, pretrained
model inference, a DICOM store/viewer, and an LLM that drafts a human-readable
report from the quantitative findings.

The goal is to **assist radiologists, not replace them** — provide a fast
"second pair of eyes" (organ volumetry, candidate lesions, structured drafts)
that a physician reviews and signs off.

> ⚠️ **Not a medical device. Research and educational use only.**
> Outputs are experimental and frequently inaccurate (see *Known limitations*).
> Nothing here is validated, CE/FDA-cleared, or fit for clinical decision-making.
> Do not use it to diagnose, treat, or make decisions about real patients.

---

## Status

🚧 **Early work-in-progress / proof of concept.** The full stack deploys and runs
end-to-end, but the clinical numbers are **not yet trustworthy**. Current focus:
making the segmentation → volumetry → report pipeline correct and reproducible
before adding tumor/anomaly detection. Contributions welcome.

---

## What's in the box

| Component | Role |
|---|---|
| **MONAI Label** | Annotation + serves MONAI Zoo model inference (REST API) |
| **MONAI Zoo bundles** | ~11 pretrained models (organ seg, lung nodule, brain, breast density, pathology…) |
| **Orthanc** | DICOM store + DICOMweb |
| **OHIF Viewer** | Browser-based DICOM viewer |
| **3D Slicer** (host) | Desktop annotation, connects to MONAI Label |
| **LLM (any OpenAI-compatible server)** | Drafts a structured radiology report from findings |
| **TotalSegmentator** | Second CT segmentation engine (comparison / ground-truth) — `scripts/inference/run-totalseg.sh` |
| **vesselFM** | Zero-shot 3D vessel segmentation (renal arteries) — `scripts/vessels/`, [VESSEL_ANALYSIS](docs/VESSEL_ANALYSIS.md) |
| Shell scripts | Full lifecycle and per-examination analyses — see [scripts/README](scripts/README.md) |

> Triton (production serving) and Holoscan (real-time streaming) are **not part of
> the default stack** — they aren't needed for stored-DICOM batch analysis and
> Holoscan needed an NGC key. Re-add them anytime via
> [docs/OPTIONAL_SERVICES.md](docs/OPTIONAL_SERVICES.md).

## Requirements

- Linux + Docker (Compose v2)
- **GPU path:** NVIDIA GPU (the custom image targets CUDA 12.8 / Blackwell). Recommended for real use.
  Reference: RTX PRO 6000 (96 GB) — runs the imaging models and a local report LLM at once.
  A 32 GB card (e.g. RTX 5090) is most likely enough for the imaging pipeline if the LLM
  runs on another machine.
- **CPU path:** no GPU needed — see below. Slower, but fine for testing.
- An OpenAI-compatible LLM endpoint (LM Studio, llama-server, vLLM, Ollama…) for report generation (optional).

## Quick start (GPU)

```bash
cp docker/.env.example docker/.env     # then edit values (see below)
./scripts/setup.sh                     # prerequisites, host Python venv, build custom image
./scripts/download-models.sh           # pull MONAI Zoo bundles
./scripts/start.sh                     # start the stack
./scripts/inference/run-inference.sh --list-models
./scripts/inference/run-inference.sh --model wholeBody_ct_segmentation --image datasets/ct/<series>
```

## Running without a GPU (CPU mode)

Set the compute device in `docker/.env`:

```ini
MOONAI_DEVICE=auto   # gpu if an NVIDIA GPU + Docker NVIDIA runtime are found, else cpu
# MOONAI_DEVICE=cpu  # force CPU (no NVIDIA driver/toolkit needed)
# MOONAI_DEVICE=gpu  # force GPU
```

`setup.sh`, `start.sh`, `restart.sh` and `logs.sh` then pick `docker/docker-compose.yml`
or `docker/docker-compose.cpu.yml` automatically, and TotalSegmentator / vesselFM run on
the same device. Everything works on CPU, just slower — on the reference host the
`wholeBody_ct_segmentation` inference took 50 s on CPU vs 2 s on the GPU; large models
(brain transformer) take tens of minutes. One-off override: `MOONAI_DEVICE=cpu ./scripts/start.sh`.

In CPU mode `pancreas_ct_dints_segmentation` is skipped: the bundle hard-codes a CUDA
device and would otherwise stop MONAI Label from starting. The LLM report step is not
affected — it runs on whatever server `LLM_BASE_URL` points to.

## Configuration

Copy `docker/.env.example` → `docker/.env` and set at least:

```ini
ORTHANC_PASSWORD=<your-own-password>     # required — start.sh refuses 'change_me'
MONAILABEL_MODELS=wholeBody_ct_segmentation,lung_nodule_ct_detection,...
LLM_BASE_URL=http://127.0.0.1:8081      # your OpenAI-compatible server
LLM_MODEL=qwen3                          # model name as your server reports it
# NGC_API_KEY is NOT needed by default (only for optional Triton/Holoscan)
```

`docker/.env` is git-ignored and is the **only** place for credentials: Orthanc gets them
from the environment, and the OHIF proxy adds them server-side, so no tracked file and
nothing sent to the browser contains a password. **Never commit real keys or passwords.**

## Documentation

Detailed guides live in [`docs/`](docs/): [SETUP](docs/SETUP.md) ·
[ARCHITECTURE](docs/ARCHITECTURE.md) · [LABELING](docs/LABELING.md) ·
[TRAINING](docs/TRAINING.md) · [INFERENCE](docs/INFERENCE.md) ·
[LLM_INTEGRATION](docs/LLM_INTEGRATION.md).

**Why this project exists**, whether it makes sense and what the alternatives are:
[PROJECT_RATIONALE](docs/PROJECT_RATIONALE.md). A summary written for a cooperating
radiologist: [RADIOLOGIST_SUMMARY](docs/RADIOLOGIST_SUMMARY.md).

**Before contributing or publishing**, read
[docs/REVIEW_AND_TODO.md](docs/REVIEW_AND_TODO.md) — it lists the known
correctness bugs (why the numbers are currently off), the security cleanup
needed, and the prioritized roadmap.

## License & data

Code: [Apache-2.0](LICENSE). Not affiliated with or endorsed by Project MONAI; MOONAI
builds on it. Third-party models keep their own licences — several (e.g. vesselFM,
nnInteractive weights) are **non-commercial / research only**; see
[REVIEW_AND_TODO](docs/REVIEW_AND_TODO.md) §5. **Never commit patient data** —
`datasets/` content is git-ignored by design.
