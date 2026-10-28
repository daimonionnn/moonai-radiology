# Scripts

Run everything from the project root (`./scripts/...`). Outputs go to `results/`
(git-ignored — patient data never enters the repository).

## Platform (this folder)

Installing, starting and managing the stack.

| Script | Purpose |
|---|---|
| `setup.sh` | Prerequisite checks, host Python env, pull/build images, create directories |
| `setup-python.sh` | Create/update the host Python venv `~/.venvs/moonai` from `requirements.txt` (used by `inference/`) |
| `build.sh` | Rebuild the custom MONAI Label image |
| `download-models.sh` | Download MONAI Model Zoo bundles |
| `install-slicer.sh` | Install 3D Slicer (+ required system libraries) |
| `start.sh` / `stop.sh` / `restart.sh` | Start / stop / restart the Docker stack |
| `status.sh` | Containers, ports, GPU |
| `logs.sh` | Follow a service's logs |
| `switch-app.sh` | Switch the MONAI Label app |
| `export_to_triton.py` | Export a trained bundle to the Triton model repository |

## Examinations (subfolders, one per analysis type)

| Folder | Scripts | Purpose | Docs |
|---|---|---|---|
| `inference/` | `run-inference.sh`, `run-totalseg.sh`, `process_findings.py`, `report_generator.py` | Run a MONAI model or TotalSegmentator on a study, organ volumes with reference-range flags, LLM report draft | [INFERENCE](../docs/INFERENCE.md), [LLM_INTEGRATION](../docs/LLM_INTEGRATION.md) |
| *(config)* | `config/prompts/` — LLM report prompts and glossary, editable text; chosen by `LLM_PROMPT_DIR` | | [config/prompts/README](../config/prompts/README.md) |
| `oncology/` | `find-tumours.sh`, `measure-lesion.sh`, `lesion_measure.py`, `nninteractive-server.sh`, `setup-slicer.sh`, `slicer_setup.py` | Automatic tumour candidates (VISTA3D); click-to-measure a CT lesion with ULS+ (volume, RECIST axes); nnInteractive server + 3D Slicer setup for interactive outlining | [ONCOLOGY](../docs/ONCOLOGY.md) |
| `vessels/` | `run-vessel-analysis.sh`, `open-vessels-in-slicer.sh`, `vessel_analysis.py`, `slicer_load_vessels.py` | Renal artery analysis: TotalSegmentator + vesselFM, bone/bowel-removed 3D view, open in 3D Slicer | [VESSEL_ANALYSIS](../docs/VESSEL_ANALYSIS.md) |

New analysis types (e.g. oncology lesion measurement) get their own subfolder with a
`run-*.sh` entry point; Python helpers live next to the shell script that calls them.
Scripts in subfolders resolve the project root as `$(dirname "$0")/../..`.
