"""
MONAI Bundle → Triton Model Repository Export
==============================================
Exports a downloaded MONAI Zoo bundle as a TorchScript model
and writes the Triton model repository ``config.pbtxt``.

This script bridges the gap between MONAI's bundle format (Python-based
ConfigWorkflow with PyTorch weights) and NVIDIA Triton Inference Server's
required directory layout with serialised TorchScript models.

Workflow
--------
1. Load the MONAI bundle metadata (``configs/metadata.json``).
2. Instantiate the network via ``ConfigWorkflow`` using the bundle's
   ``inference.json`` (or ``.yaml``) configuration.
3. Trace or script the model to TorchScript (``torch.jit.trace`` preferred,
   ``torch.jit.script`` as fallback for models with dynamic control flow).
4. Save as ``<out>/<name>/1/model.pt`` (Triton's versioned model layout).
5. Write ``<out>/<name>/config.pbtxt`` with input/output tensor specs.

Triton will auto-reload the model within 30s (poll interval set in
``docker-compose.yml``).  Verify with::

    curl http://localhost:8002/v2/models/<name>

Usage::

    python scripts/export_to_triton.py \\
        --bundle models/bundles/brats_mri_segmentation \\
        --out    models/triton \\
        --name   brats_mri_seg

Requirements
-----------
- PyTorch (with CUDA for GPU tracing)
- MONAI Core (``monai.bundle.ConfigWorkflow``)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import textwrap
from pathlib import Path

try:
    import torch
    import monai
    from monai.bundle import ConfigWorkflow
except ImportError as e:
    print(f"[ERROR] Missing dependency: {e}")
    print("Install: pip install monai torch")
    sys.exit(1)


# ────────────────────────────────────────────────────────────
#  Triton pbtxt templates
# ────────────────────────────────────────────────────────────
# Triton requires a config.pbtxt file alongside each model that declares
# the model platform, input/output tensor shapes, and GPU instance config.
# This template targets PyTorch TorchScript models ("pytorch_libtorch").
# Batch dimension is handled by Triton (max_batch_size=1), so dims in the
# template exclude the batch axis (e.g. [1, 240, 240, 160] for BraTS).
PBTXT_TORCHSCRIPT = textwrap.dedent("""\
    name: "{name}"
    platform: "pytorch_libtorch"
    max_batch_size: 1

    input [
      {{
        name: "INPUT__0"
        data_type: TYPE_FP32
        dims: {input_dims}
      }}
    ]

    output [
      {{
        name: "OUTPUT__0"
        data_type: TYPE_FP32
        dims: {output_dims}
      }}
    ]

    instance_group [
      {{
        count: 1
        kind: KIND_GPU
        gpus: [ 0 ]
      }}
    ]

    optimization {{
      execution_accelerators {{
        gpu_execution_accelerator: [
          {{
            name: "cuda"
          }}
        ]
      }}
    }}
""")

# ────────────────────────────────────────────────────────────
#  Known I/O shapes per bundle (fallback if inference fails)
# ────────────────────────────────────────────────────────────
# Hard-coded tensor shapes for known MONAI Zoo bundles.  These are used
# both for creating a dummy input tensor (for torch.jit.trace) and for
# writing the Triton config.pbtxt I/O specifications.
#
# Format: [batch, channels, dim1, dim2, dim3]
# -1 denotes the dynamic batch axis (handled by Triton's max_batch_size).
BUNDLE_SHAPES: dict[str, dict] = {
    "brats_mri_segmentation": {
        "input":  [-1, 1, 240, 240, 160],   # (batch, channel, D, H, W)
        "output": [-1, 3, 240, 240, 160],   # 3 classes: WT, TC, ET
    },
    "lung_nodule_ct_detection": {
        "input":  [-1, 1, 192, 192, 80],
        "output": [-1, 6],                  # detection boxes
    },
    "spleen_ct_segmentation": {
        "input":  [-1, 1, 96, 96, 96],
        "output": [-1, 2, 96, 96, 96],
    },
    "swin_unetr_btcv_segmentation": {
        "input":  [-1, 1, 96, 96, 96],
        "output": [-1, 14, 96, 96, 96],
    },
    "prostate_mri_anatomy": {
        "input":  [-1, 1, 320, 320, 32],
        "output": [-1, 3, 320, 320, 32],
    },
}


def _dims_str(dims: list[int]) -> str:
    """Format tensor dimensions for Triton pbtxt.

    Triton's config.pbtxt expects dims *without* the batch axis (which is
    handled by ``max_batch_size``).  We strip the first element (batch dim)
    and format the remainder as a bracket-enclosed list with spaces.

    Example: ``[-1, 1, 240, 240, 160]`` → ``"[ 1, 240, 240, 160 ]"``.
    """
    return str(dims[1:]).replace("[", "[ ").replace("]", " ]")


def export_bundle(bundle_path: str, out_dir: str, model_name: str) -> None:
    """
    Export a MONAI bundle to Triton's model repository format.

    This function performs the complete export pipeline:

    1. **Load metadata** — reads ``configs/metadata.json`` for the bundle
       name and version (informational only).
    2. **Instantiate model** — uses MONAI's ``ConfigWorkflow`` to parse the
       inference config and build the PyTorch ``nn.Module``.
    3. **Determine I/O shapes** — looks up the bundle name in
       ``BUNDLE_SHAPES``; falls back to a generic 96³ cube if unknown.
    4. **TorchScript export** — ``torch.jit.trace`` with a dummy input
       tensor, falling back to ``torch.jit.script`` for models with
       data-dependent control flow that tracing cannot capture.
    5. **Save artifacts** — writes ``model.pt`` and ``config.pbtxt``
       to the Triton repository directory.

    Parameters
    ----------
    bundle_path : str
        Path to the downloaded MONAI bundle directory (e.g.
        ``models/bundles/brats_mri_segmentation``).
    out_dir : str
        Root of the Triton model repository (e.g. ``models/triton``).
    model_name : str
        Name for the exported model in Triton (used as directory name
        and in ``config.pbtxt``).
    """
    bundle_path = Path(bundle_path).resolve()
    out_dir     = Path(out_dir).resolve()

    if not bundle_path.exists():
        print(f"[ERROR] Bundle not found: {bundle_path}")
        sys.exit(1)

    # ── Load metadata ──────────────────────────────────────
    meta_file = bundle_path / "configs" / "metadata.json"
    if meta_file.exists():
        with open(meta_file) as f:
            metadata = json.load(f)
        print(f"[info] Bundle: {metadata.get('name','?')}  v{metadata.get('version','?')}")
    else:
        print("[warn] metadata.json not found, proceeding anyway")
        metadata = {}

    # ── Instantiate model ──────────────────────────────────
    inference_cfg = bundle_path / "configs" / "inference.json"
    if not inference_cfg.exists():
        inference_cfg = bundle_path / "configs" / "inference.yaml"
    if not inference_cfg.exists():
        print(f"[ERROR] No inference config found in {bundle_path}/configs/")
        sys.exit(1)

    print(f"[info] Loading model from: {inference_cfg}")
    try:
        workflow = ConfigWorkflow(
            workflow_type="infer",
            config_file=str(inference_cfg),
            bundle_root=str(bundle_path),
            logging_file=str(bundle_path / "configs" / "logging.conf")
            if (bundle_path / "configs" / "logging.conf").exists() else None,
        )
        workflow.initialize()
        model = workflow.network_def.eval()
    except Exception as e:
        print(f"[ERROR] Failed to load model: {e}")
        print("[hint] The bundle may use a custom network not exportable via this script.")
        sys.exit(1)

    # ── Get I/O shapes ──────────────────────────────────────
    # Look up known tensor dimensions for this bundle.  These define
    # the dummy input shape for tracing and the Triton I/O config.
    shapes = BUNDLE_SHAPES.get(bundle_path.name, None)
    if shapes is None:
        print("[warn] Unknown bundle shape. Using generic 1×1×96×96×96 input.")
        shapes = {"input": [-1, 1, 96, 96, 96], "output": [-1, 1, 96, 96, 96]}

    # Build dummy input: replace -1 batch dim with 1 for tracing
    input_shape = shapes["input"]
    dummy_batch = [1] + input_shape[1:]
    dummy_input = torch.zeros(dummy_batch, dtype=torch.float32)

    # ── TorchScript trace ────────────────────────────────────
    # torch.jit.trace records operations on a concrete input tensor.
    # This works for most MONAI architectures (UNet, SegResNet, SwinUNETR)
    # but fails for models with data-dependent branching.  In that case
    # we fall back to torch.jit.script which parses the Python source.
    print("[info] Tracing to TorchScript...")
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = model.to(device)
    dummy_input = dummy_input.to(device)

    try:
        traced = torch.jit.trace(model, dummy_input)
    except Exception:
        print("[warn] Trace failed, trying torch.jit.script...")
        try:
            traced = torch.jit.script(model)
        except Exception as e2:
            print(f"[ERROR] TorchScript export failed: {e2}")
            sys.exit(1)

    # ── Save model ──────────────────────────────────────────
    model_dir = out_dir / model_name / "1"
    model_dir.mkdir(parents=True, exist_ok=True)
    model_pt = model_dir / "model.pt"
    traced.save(str(model_pt))
    print(f"[ok]   Saved: {model_pt}")

    # ── Write config.pbtxt ──────────────────────────────────
    config_pbtxt = out_dir / model_name / "config.pbtxt"
    config_content = PBTXT_TORCHSCRIPT.format(
        name=model_name,
        input_dims=_dims_str(input_shape),
        output_dims=_dims_str(shapes["output"]),
    )
    config_pbtxt.write_text(config_content)
    print(f"[ok]   Written: {config_pbtxt}")

    print()
    print(f"Model '{model_name}' exported to Triton repository at: {out_dir / model_name}")
    print(f"Verify (once Triton is running):  curl http://localhost:8002/v2/models/{model_name}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Export MONAI bundle → Triton repository")
    parser.add_argument("--bundle", required=True, help="Path to downloaded MONAI bundle directory")
    parser.add_argument("--out",    default="models/triton", help="Triton model repository root")
    parser.add_argument("--name",   default="", help="Model name in Triton (default: bundle dir name)")
    args = parser.parse_args()

    model_name = args.name or Path(args.bundle).name
    export_bundle(args.bundle, args.out, model_name)


if __name__ == "__main__":
    main()
