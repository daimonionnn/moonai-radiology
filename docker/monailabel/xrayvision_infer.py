"""
TorchXRayVision CXR/RTG Pathology Inference Wrapper
====================================================
Exposes a MONAI Label-compatible /infer/cxr_pathology endpoint.
Run standalone:  python xrayvision_infer.py --port 8010
Or call infer() directly from other scripts.

Detects 14 pathologies:
  Atelectasis, Cardiomegaly, Effusion, Infiltration, Mass,
  Nodule, Pneumonia, Pneumothorax, Consolidation, Edema,
  Emphysema, Fibrosis, Pleural Thickening, Hernia
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torchxrayvision as xrv
import torchxrayvision.models as xrv_models
from torchvision import transforms

# ── Optional DICOM / NIfTI loading ──────────────────────────
try:
    import pydicom
    _HAVE_PYDICOM = True
except ImportError:
    _HAVE_PYDICOM = False

try:
    import nibabel as nib
    _HAVE_NIBABEL = True
except ImportError:
    _HAVE_NIBABEL = False

try:
    from PIL import Image
    _HAVE_PIL = True
except ImportError:
    _HAVE_PIL = False


# ────────────────────────────────────────────────────────────
#  Model singleton
# ────────────────────────────────────────────────────────────
_MODEL: xrv_models.DenseNet | None = None
DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

PATHOLOGIES = [
    "Atelectasis", "Cardiomegaly", "Effusion", "Infiltration",
    "Mass", "Nodule", "Pneumonia", "Pneumothorax",
    "Consolidation", "Edema", "Emphysema", "Fibrosis",
    "Pleural Thickening", "Hernia",
]

ABNORMALITY_THRESHOLD = 0.35  # confidence above this is flagged


def _load_model() -> xrv_models.DenseNet:
    global _MODEL
    if _MODEL is None:
        print("[xrayvision] Loading DenseNet-121 CheXpert weights …", flush=True)
        # all-224 model trained on 12 datasets — best general chest X-ray model
        _MODEL = xrv.models.DenseNet(weights="densenet121-res224-all")
        _MODEL.to(DEVICE)
        _MODEL.eval()
        print(f"[xrayvision] Model loaded on {DEVICE}", flush=True)
    return _MODEL


def _preprocess(image_path: str | Path) -> torch.Tensor:
    """Load any supported format and return (1, 1, 224, 224) tensor."""
    path = Path(image_path)
    suffix = path.suffix.lower()

    img_array: np.ndarray | None = None

    if suffix in (".dcm",) and _HAVE_PYDICOM:
        ds = pydicom.dcmread(str(path))
        img_array = ds.pixel_array.astype(np.float32)

    elif suffix in (".nii", ".gz") and _HAVE_NIBABEL:
        nii = nib.load(str(path))
        data = nii.get_fdata()
        # take centre axial slice if 3D
        if data.ndim == 3:
            mid = data.shape[2] // 2
            img_array = data[:, :, mid].astype(np.float32)
        else:
            img_array = data.astype(np.float32)

    elif suffix in (".png", ".jpg", ".jpeg", ".bmp", ".tiff") and _HAVE_PIL:
        img_pil = Image.open(str(path)).convert("L")
        img_array = np.array(img_pil, dtype=np.float32)

    else:
        raise ValueError(f"Unsupported or unreadable file: {path}")

    # Normalise to [-1024, 1024] range expected by TorchXRayVision
    img_array = xrv.datasets.normalize(img_array, maxval=255)

    # Resize to 224×224
    transform = transforms.Compose([
        xrv.datasets.XRayCenterCrop(),
        xrv.datasets.XRayResizer(224),
    ])
    img_array = transform(img_array[None])  # (1, H, W)
    tensor = torch.from_numpy(img_array).unsqueeze(0).to(DEVICE)  # (1, 1, 224, 224)
    return tensor


# ────────────────────────────────────────────────────────────
#  Public inference function
# ────────────────────────────────────────────────────────────
def infer(image_path: str | Path) -> dict[str, Any]:
    """
    Run CXR pathology inference on a single image.

    Returns
    -------
    {
        "model": "cxr_pathology",
        "image": "<path>",
        "predictions": {
            "Atelectasis": 0.12,
            "Pneumonia":   0.72,
            ...
        },
        "findings": ["Pneumonia"],          # above threshold
        "abnormal": true,
        "threshold_used": 0.35
    }
    """
    model = _load_model()
    tensor = _preprocess(image_path)

    with torch.no_grad():
        preds = model(tensor).squeeze().cpu().numpy()  # (14,) or (N,)

    # Align to standard 14 pathologies
    pred_dict: dict[str, float] = {}
    for i, name in enumerate(PATHOLOGIES):
        # TorchXRayVision model may expose fewer; guard with index check
        pred_dict[name] = float(preds[i]) if i < len(preds) else 0.0

    findings = [k for k, v in pred_dict.items() if v >= ABNORMALITY_THRESHOLD]

    return {
        "model": "cxr_pathology",
        "image": str(image_path),
        "predictions": pred_dict,
        "findings": findings,
        "abnormal": len(findings) > 0,
        "threshold_used": ABNORMALITY_THRESHOLD,
    }


# ────────────────────────────────────────────────────────────
#  Optional standalone FastAPI micro-server
# ────────────────────────────────────────────────────────────
def _run_server(port: int = 8010) -> None:
    try:
        from fastapi import FastAPI, File, UploadFile
        from fastapi.responses import JSONResponse
        import uvicorn
    except ImportError:
        print("fastapi/uvicorn not installed. Install with: pip install fastapi uvicorn", file=sys.stderr)
        sys.exit(1)

    app = FastAPI(title="CXR Pathology Inference", version="1.0")

    @app.get("/health")
    def health():
        return {"status": "ok", "device": str(DEVICE)}

    @app.post("/infer/cxr_pathology")
    async def infer_endpoint(file: UploadFile = File(...)):
        suffix = Path(file.filename).suffix
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
            tmp.write(await file.read())
            tmp_path = tmp.name
        try:
            result = infer(tmp_path)
        finally:
            os.unlink(tmp_path)
        return JSONResponse(result)

    # Pre-load model at startup
    _load_model()
    print(f"[xrayvision] Serving on http://0.0.0.0:{port}", flush=True)
    uvicorn.run(app, host="0.0.0.0", port=port)


# ────────────────────────────────────────────────────────────
#  CLI entry point
# ────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="TorchXRayVision CXR Pathology Inference")
    subparsers = parser.add_subparsers(dest="command")

    # infer sub-command
    p_infer = subparsers.add_parser("infer", help="Run inference on a single file")
    p_infer.add_argument("image", help="Path to DICOM, NIfTI, or PNG image")

    # serve sub-command
    p_serve = subparsers.add_parser("serve", help="Start standalone FastAPI server")
    p_serve.add_argument("--port", type=int, default=8010)

    args = parser.parse_args()

    if args.command == "infer":
        result = infer(args.image)
        print(json.dumps(result, indent=2))
    elif args.command == "serve":
        _run_server(args.port)
    else:
        parser.print_help()
