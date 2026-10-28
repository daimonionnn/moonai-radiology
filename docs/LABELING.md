# Labeling / Annotation Guide

## Overview

MONAI Label provides an **active learning** annotation server.  
The workflow:

1. Upload studies (DICOM or NIfTI)
2. MONAI Label suggests the *most informative* unlabeled sample (active learning)
3. AI pre-labels the image (segmentation or detection)
4. Radiologist reviews and corrects in 3D Slicer or OHIF
5. Corrected label is saved back to the server
6. Repeat → model improves with each labeling iteration

---

## 3D Slicer Workflow (recommended for 3D MRI/CT)

### Install

```bash
./scripts/install-slicer.sh
```

Downloads 3D Slicer 5.10.0 (~1 GB) to `~/slicer/`, creates a `/usr/local/bin/slicer3d` launcher
and a desktop shortcut. Then install the **MONAILabel** extension inside Slicer:

1. Open Slicer: `slicer3d`
2. **View → Extension Manager** → search `MONAI Label` → Install → restart Slicer

### Connect

1. Start platform: `./scripts/start.sh`
2. Open 3D Slicer: `slicer3d`
3. Search for **MONAI Label** in the module finder
4. Set server URL: `http://localhost:8000`
5. Click **Refresh Server**

### Annotate a Study

```
1.  Click [Next Sample]
    → MONAI Label returns the most informative unlabeled study

2.  Select a model from the dropdown
    – Brain MRI (standard T1 series): wholeBrainSeg_Large_UNEST_segmentation
    – CT (whole body):                 wholeBody_ct_segmentation
    – CT (pancreas):                   pancreas_ct_dints_segmentation
    – Interactive (any):              vista3d
    ⚠️  brats_mri_segmentation requires a 4-channel BraTS NIfTI — not standard DICOM

3.  Click [Run]
    → AI generates a segmentation displayed as a label map over the image

4.  In the Segment Editor (shortcut: E):
    - Add/remove regions with Paint / Erase tools
    - Use Threshold to extend/trim
    - Run SmartEdit (DeepEdit) — click foreground/background points to refine

5.  Click [Submit Label]
    → Label saved to MONAI Label datastore at /workspace/datasets/<id>/label/final/

6.  (Optional) Click [Next Sample] and repeat
```

### Interactive Segmentation Models

| Model | Interaction | Use case |
|---|---|---|
| `deepedit` | Foreground/background clicks | Generic 3D segmentation |
| `deepgrow_2d` / `deepgrow_3d` | Clicks on 2D/3D | Quick rough segmentation |
| `vista3d` | Click or automatic | Universal interactive 3D |

In MONAI Label module → **Interaction** tab → place green dots (foreground) and red dots (background).

---

## OHIF Browser Workflow (DICOM studies in Orthanc)

1. Open http://localhost:3000
2. Select a study from the list
3. In the toolbar look for the **MONAI** button (requires OHIF MONAI Label extension)
4. Select model → click **Run AI** → segmentation overlaid on viewer
5. Edit with OHIF annotation tools
6. Click **Save** → label sent to MONAI Label

> Note: OHIF provides 2D annotation tools. For 3D volumetric editing, use 3D Slicer.

---

## Supported Modalities

| Modality | Format | Recommended App | Model examples |
|---|---|---|---|
| MRI (brain) | DICOM, NIfTI | `monaibundle` | `wholeBrainSeg_Large_UNEST_segmentation`, `prostate_mri_anatomy` |
| MRI (brain tumor) | NIfTI **4-ch BraTS** | `monaibundle` | `brats_mri_segmentation` (requires T1/T1ce/T2/FLAIR stacked) |
| CT (chest, abdomen, whole-body) | DICOM, NIfTI | `monaibundle` | `lung_nodule_ct_detection`, `wholeBody_ct_segmentation`, `swin_unetr_btcv_segmentation`, `pancreas_ct_dints_segmentation` |
| Mammography | DICOM | `monaibundle` | `breast_density_classification` |
| Pathology / WSI | TIFF, SVS | `pathology` | `pathology_tumor_detection`, `pathology_nuclei_segmentation_classification` |

---

## Switching Apps

```bash
# Switch to pathology app (for WSI)
./scripts/switch-app.sh pathology

# Switch back to default bundle app
./scripts/switch-app.sh monaibundle
```

Or set `MONAILABEL_APP=pathology` in `docker/.env` and restart.

---

## Label Storage

Labels are stored locally by MONAI Label in the datastore:

```
datasets/<modality>/<study_id>/
    label/
        final/
            <study_id>.nii.gz     ← saved annotation
        original/
            <study_id>.nii.gz     ← first AI prediction (before editing)
```

---

## REST API — Key Endpoints

```bash
# Get next sample to label (active learning)
curl http://localhost:8000/activelearning/random

# Run inference (AI pre-label) and save result
curl -X POST http://localhost:8000/infer/brats_mri_segmentation \
    -F "file=@brain_mri.nii.gz"

# Save a label
curl -X PUT http://localhost:8000/label/<image_id> \
    -F "params={}" \
    -F "label=@my_label.nii.gz"

# List all studies in datastore
curl http://localhost:8000/datastore/

# Trigger training
curl -X POST http://localhost:8000/train/brats_mri_segmentation

# Check training status
curl http://localhost:8000/train/brats_mri_segmentation
```

---

## Active Learning Strategies

MONAI Label supports several strategies for selecting the next sample:

| Strategy | Description |
|---|---|
| `random` | Random unlabeled sample |
| `first` | First unlabeled in order |
| `epistemic` | Highest uncertainty (requires scoring pass) |
| `tta` | Test-Time Augmentation uncertainty |

```bash
# Use epistemic uncertainty (highest model uncertainty first)
curl http://localhost:8000/activelearning/epistemic
```

Run an uncertainty scoring pass before using epistemic:
```bash
curl -X POST http://localhost:8000/scoring/epistemic_v2
```
