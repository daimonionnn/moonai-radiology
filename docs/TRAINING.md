# Training Guide

## Overview

MONAI Label fine-tunes pretrained Zoo bundles on your labeled data.  
Training is triggered via REST API and runs in the background inside the container.  
Progress is logged to TensorBoard.

---

## Fine-tuning via MONAI Label API

### Start Training

```bash
# Trigger fine-tuning of a specific model
curl -X POST "http://localhost:8000/train/brats_mri_segmentation" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "brats_mri_segmentation",
        "max_epochs": 50,
        "val_split": 0.2,
        "dataset": "CacheDataset"
    }'
```

### Monitor Training Status

```bash
# Check if training is running
curl http://localhost:8000/train/brats_mri_segmentation

# Stop training
curl -X DELETE http://localhost:8000/train/brats_mri_segmentation
```

### TensorBoard

```bash
# Open in browser
http://localhost:6006
```

Training metrics (loss, dice score, validation dice) are written to:
`./storage/tensorboard/`

---

## How MONAI Label Fine-tuning Works

1. Labeled pairs `(image.nii.gz, label.nii.gz)` are in the datastore
2. MONAI Label loads bundle hyperparameters from `configs/train.json`
3. Trains for `max_epochs` (default varies per bundle)
4. Best checkpoint saved to `apps/<app>/model/<bundle>/best_model.pt`
5. Model is hot-reloaded for inference — no restart needed

---

## Custom Training with MONAI Core

For full control, train outside MONAI Label using MONAI Core directly.

### Example — Fine-tune BraTS Segmentation

```python
# train_brats.py
from monai.bundle import ConfigWorkflow

workflow = ConfigWorkflow(
    workflow_type="train",
    config_file="models/bundles/brats_mri_segmentation/configs/train.json",
    bundle_root="models/bundles/brats_mri_segmentation",
    # Override config values:
    max_epochs=100,
    train_batch_size=2,
    val_interval=5,
    learning_rate=1e-4,
    dataset_dir="datasets/mri",
)
workflow.initialize()
workflow.run()
workflow.finalize()
```

```bash
# Run inside container
docker exec -it monailabel python3 /workspace/train_brats.py
```

### Key Training Parameters (overrideable)

| Parameter | Default | Description |
|---|---|---|
| `max_epochs` | 300 | Training epochs |
| `train_batch_size` | 1 | Batch size (increase if VRAM allows) |
| `val_interval` | 5 | Validate every N epochs |
| `learning_rate` | 1e-4 | Initial LR |
| `val_split` | 0.2 | Fraction of data for validation |
| `roi_size` | bundle-specific | Patch size for sliding window inference |

---

## Data Preparation

### For MONAI Label (local mode)

Structure your labeled data as:

```
datasets/mri/
    Patient_001/
        image.nii.gz
        label/
            final/
                Patient_001.nii.gz    ← ground truth segmentation
    Patient_002/
        ...
```

MONAI Label auto-discovers paired data.

### For MONAI Core (manual)

Use a standard dataset JSON:

```python
# Create dataset_config.json
import json
samples = [
    {"image": "datasets/mri/P001/image.nii.gz",
     "label": "datasets/mri/P001/label/final/P001.nii.gz"},
    # ...
]
json.dump({"training": samples}, open("dataset_config.json","w"))
```

---

## Model Export After Training

After training, export your fine-tuned model to Triton for production inference:

```bash
# Export fine-tuned bundle to Triton model repository
python scripts/export_to_triton.py \
    --bundle models/bundles/brats_mri_segmentation \
    --out    models/triton \
    --name   brats_finetuned

# Triton will auto-pick up the new model within 30 seconds
curl http://localhost:8010/v2/models/brats_finetuned
```

---

## Recommended Training Settings

| Bundle | `roi_size` | `batch_size` | `max_epochs` |
|---|---|---|---|
| `brats_mri_segmentation` | `[240,240,160]` | 1–2 | 300 |
| `lung_nodule_ct_detection` | `[192,192,80]` | 2–4 | 200 |
| `wholeBody_ct_segmentation` | `[96,96,96]` | 4 | 200 |
| `swin_unetr_btcv_segmentation` | `[96,96,96]` | 2 | 250 |
| `vista3d` | `[128,128,128]` | 2 | 300 |

These settings fit a 32 GB GPU (e.g. RTX 5090), which handles `batch_size=2–4` for most
3D models. On the reference RTX PRO 6000 (96 GB) you can use a larger `batch_size` or
`roi_size` — but leave headroom if a local report LLM shares the GPU.

---

## Monitoring GPU During Training

```bash
# Continuous GPU monitoring
watch -n 2 nvidia-smi

# CUDA memory summary inside container
docker exec monailabel python3 -c "
import torch
print(torch.cuda.memory_summary(device=0))
"
```

---

## MONAI Zoo Bundle Fine-tuning Checklist

```
□  At least 10–20 labeled studies available
□  Labels verified (correct classes, no artifacts)
□  docker/.env MONAILABEL_MODELS includes the target bundle
□  monailabel container running and model loaded
□  TensorBoard open at localhost:6006
□  POST /train/<model> triggered
□  Monitor: dice score improving, loss decreasing
□  After training: test with a new unseen image
□  If satisfactory: export to Triton with export_to_triton.py
```
