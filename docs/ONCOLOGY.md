# Oncology tools

Measure and follow tumours. **Research use only** — not a medical device; every outline
must be checked by a physician. Status and next steps: [TODO](TODO.md) P1.

## Click-to-measure any CT lesion (ULS+)

[ULS+](https://github.com/DIAGNijmegen/oncology-uls-plus) (Radboud, 2026) segments the
lesion at a point you give it — lung nodule, liver metastasis, lymph node, kidney or
bone lesion — and the script reports the volume and RECIST-style axes. It is **not a
detector**: it measures what you point at.

```bash
./scripts/oncology/measure-lesion.sh --image <ct.nii.gz | DICOM dir> --point=x,y,z --label liver_met_1
```

- `--point=x,y,z` — world coordinate in mm, **RAS** as 3D Slicer shows it (place a
  markup point on the lesion and copy its coordinates, or read them in the Data Probe).
  Use `--point=` with `=` when the first value is negative. `--voxel` takes an i,j,k index.
- Output (`results/<timestamp>_lesion_<label>/`): `<label>_mask.nii.gz` on the CT grid
  (load it over the CT in Slicer) and `<label>.json`:

```json
{"volume_ml": 7.43, "long_axis_mm": 30.2, "short_axis_mm": 24.1, "centre_ras_mm": [-162.1, -296.6, -158.8], ...}
```

**How it works** (`scripts/oncology/lesion_measure.py`): a volume of interest of
128×256×256 voxels (the ULS23 convention) is cropped around the point at native spacing,
segmented by ULS+ (nnU-Net v2 ResEnc-L, from the TotalSegmentator venv), pasted back,
and the component at the point is kept. Long axis = longest in-plane diameter over the
axial slices; short axis = longest diameter perpendicular to it on the same slice.
~10 s per lesion on the reference GPU.

**Tested** on 9 expert-annotated lesions in three public CTs (lung nodule, 7 liver
metastases, kidney tumour): mean **Dice 0.71**, all 9 measured — see
[PUBLIC_DATA_TESTS](research/PUBLIC_DATA_TESTS.md). Weakest on tiny lesions on thick
slices (0.08 mL on 5 mm slices: Dice 0.35).

**Caveats**

- Prompt-based models give slightly different masks for different click positions —
  relevant for follow-up comparisons; click the lesion centre.
- Weights: [huggingface.co/nielsRocholl/ULS_plus](https://huggingface.co/nielsRocholl/ULS_plus),
  downloaded on first use to `models/uls_plus/` (~0.8 GB, git-ignored). The licence is
  stated inconsistently (CC BY-NC-SA 4.0 on Hugging Face, CC BY-SA 4.0 on Zenodo, an
  Apache-2.0 text in the model README) — treat it as **non-commercial research only**.
- The plans use a custom "no resampling" function from the ULS+ repository; the script
  registers it at runtime instead of modifying the installed nnU-Net.

## Automatic tumour candidates (VISTA3D)

```bash
./scripts/oncology/find-tumours.sh --image <ct.nii.gz | DICOM dir> [--classes lung,liver,pancreas,colon,bone]
```

Runs the VISTA3D bundle (in the `monailabel` container) with its tumour classes as the
prompt — its automatic "segment everything" mode leaves them out — and lists each
connected lesion with volume, extent and centre (RAS, usable as `--point` for
`measure-lesion.sh`). Output: `results/<timestamp>_tumours_<name>/` (`tumours_mask.nii.gz`,
`summary.json`). On the public cases: lung nodule found (Dice 0.82, 1 false positive),
liver metastases 4/7 found with no false positives (Dice 0.64). **Candidates only** —
small lesions on thick slices are missed. There is no kidney-tumour class.

## Interactive segmentation in 3D Slicer (nnInteractive)

[nnInteractive](https://github.com/MIC-DKFZ/nnInteractive) (DKFZ, CVPR 2025 challenge
winner) turns points, scribbles, boxes and lasso strokes into a 3D mask, and you refine
it with more prompts (positive / negative) while you watch. Use it to outline or correct a
lesion — or any structure — that no automatic model handles.

```bash
./scripts/oncology/setup-slicer.sh          # once (and after a Slicer upgrade)
./scripts/oncology/nninteractive-server.sh  # keep running while you work
```

Then in 3D Slicer: module **nnInteractive** → **Initialize** → choose a prompt type and
click/draw on the lesion; add negative points where it leaks.

- `setup-slicer.sh` installs the Slicer extensions NNInteractive, SlicerVMTK, MONAILabel
  and TotalSegmentator, the torch-free `nninteractive-client` into Slicer's Python, and
  sets Remote mode with server `http://localhost:1527`.
- The server runs on the host from `~/.venvs/nninteractive` (PyTorch for CUDA 12.8; setup in
  the script header). The official Docker image ships PyTorch 2.6, which has **no
  Blackwell (sm_120) kernels** and fails on the RTX PRO 6000 / RTX 5090. The model
  (~0.4 GB) is downloaded to `models/nninteractive/` on first start; ~10 GB VRAM.
- It listens on `localhost` only; set `NNINTERACTIVE_API_KEY` in `docker/.env` to require
  a key (Slicer then asks for it each session — the extension does not store keys).
- Licence: code Apache-2.0, weights CC BY-NC-SA 4.0 — non-commercial research only.

**Measured without interaction** (one prompt, no corrections; 9 public lesions):
one click in the lesion centre → mean Dice 0.31 (on small liver metastases a single click
often grew into the whole liver); one axial box → 0.48. That is not how the tool is meant
to be used — it relies on further prompts — but it shows the role split: **ULS+ for
one-click measurement, nnInteractive for interactive outlining and correction.**

## Coming next (TODO P1)
- **LesionLocator** — follow-up: propagate a lesion mask to the next scan and compare
  (RECIST 1.1 change table).
- Results as DICOM SEG/SR into Orthanc, so OHIF shows them.
