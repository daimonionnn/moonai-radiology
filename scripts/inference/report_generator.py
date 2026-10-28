"""
MONAI Platform — Radiology Report Generator
============================================
Connects MONAI Label inference results to LM Studio (or any
OpenAI-compatible LLM server) to produce structured radiology reports.

This module provides an alternative entry point to the inference→report
pipeline.  While ``run-inference.sh`` handles the full workflow in bash,
this Python script can be used standalone to:

- Re-generate a report from a previously saved findings JSON file.
- Pipe inference JSON from stdin (useful in CI/scripting).
- Run inference + report generation entirely from Python.

The LLM prompt is selected from a library of modality-specific templates
(brain MRI, lung CT, CXR, mammography, pathology, etc.) to produce
clinically appropriate report structure and terminology.

Usage::

    # From inference JSON file
    python scripts/inference/report_generator.py --findings output.json

    # Direct model + image via MONAI Label REST API
    python scripts/inference/report_generator.py \\
        --model brats_mri_segmentation \\
        --image datasets/mri/<series>/DICOM/00000001/00000001

    # Pipe findings JSON from stdin
    curl http://localhost:8000/infer/brats_mri_segmentation \\
        -F "file=@image.dcm" | python scripts/inference/report_generator.py --stdin

Environment variables (or set in ``docker/.env``)::

    LLM_BASE_URL    (default: http://localhost:1234)
    LLM_MODEL       (default: llama-3.1-8b-instruct)
    LLM_MAX_TOKENS  (default: 2048)
    LLM_TEMPERATURE (default: 0.2)
    MONAILABEL_PORT (default: 8000)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import textwrap
from datetime import datetime
from pathlib import Path
from typing import Any

# Optional HTTP client
# httpx is preferred for its modern API and connection pooling,
# but we fall back to stdlib urllib if it's not installed.
try:
    import httpx
    _HTTP = "httpx"
except ImportError:
    import urllib.request
    import urllib.error
    _HTTP = "urllib"

# ────────────────────────────────────────────────────────────
#  Configuration
# ────────────────────────────────────────────────────────────
# All config is sourced from environment variables with sensible defaults.
# These can be set in docker/.env or exported in the shell.
LLM_BASE_URL  = os.getenv("LLM_BASE_URL",   "http://localhost:1234")  # LM Studio server
LLM_MODEL     = os.getenv("LLM_MODEL",       "llama-3.1-8b-instruct")     # Model identifier
LLM_MAX_TOK   = int(os.getenv("LLM_MAX_TOKENS", "2048"))                  # Max generation tokens
LLM_TEMP      = float(os.getenv("LLM_TEMPERATURE", "0.2"))                # Low temp = factual
ML_PORT       = int(os.getenv("MONAILABEL_PORT", "8000"))                  # MONAI Label port
ML_BASE_URL   = f"http://localhost:{ML_PORT}"

# ── Reporting templates per modality ──────────────────────────
REPORT_TEMPLATES: dict[str, str] = {

    "default": textwrap.dedent("""\
        You are an expert radiologist AI assistant. Generate a concise, structured radiology report \
        based on the automated AI analysis results below.

        Structure the report as:
        1. TECHNIQUE / MODALITY
        2. COMPARISON (if known)
        3. FINDINGS
        4. IMPRESSION / DIAGNOSIS
        5. RECOMMENDATION

        AI model used: {model}
        Analysis timestamp: {timestamp}
        AI findings summary:
        {findings}

        Generate the report now (in professional medical language):
    """),

    "brats_mri_segmentation": textwrap.dedent("""\
        You are a neuroradiologist AI assistant. The following data is from an automated MRI brain \
        tumor segmentation (BraTS). Generate a professional structured radiology report.

        Model: SegResNet (BraTS — Whole Tumor / Tumor Core / Enhancing Tumor)
        Modality: MRI Brain
        Timestamp: {timestamp}

        Segmentation results:
        {findings}

        Report structure:
        1. CLINICAL INDICATION
        2. TECHNIQUE
        3. FINDINGS (describe tumor location, size estimate, signal characteristics, \
        whole tumor / tumor core / enhancing tumor regions)
        4. IMPRESSION (likely diagnosis, differential diagnosis)
        5. RECOMMENDATION (follow-up, biopsy consideration, oncology referral)
    """),

    "lung_nodule_ct_detection": textwrap.dedent("""\
        You are a thoracic radiologist AI assistant. The following is from an automated CT lung \
        nodule detection (RetinaNet, LUNA16-trained).

        Model: Lung Nodule CT Detection (RetinaNet)
        Modality: CT Chest
        Timestamp: {timestamp}

        Detection results:
        {findings}

        Report structure:
        1. CLINICAL INDICATION
        2. TECHNIQUE
        3. FINDINGS (list detected nodules with location, estimated size, morphology if available)
        4. IMPRESSION (Fleischner Society classification if applicable)
        5. RECOMMENDATION (Fleischner follow-up interval, PET/CT, biopsy indication)
    """),

    "cxr_pathology": textwrap.dedent("""\
        You are a radiologist AI assistant specialising in chest X-ray interpretation. \
        The following probabilities are from TorchXRayVision automated CXR pathology detection.

        Model: DenseNet-121 (TorchXRayVision, trained on 12 datasets)
        Modality: Chest X-ray (PA/AP)
        Timestamp: {timestamp}

        Pathology probabilities:
        {findings}

        Report structure:
        1. TECHNIQUE
        2. FINDINGS (describe each flagged pathology with its probability; note normal structures if applicable)
        3. IMPRESSION (primary diagnosis, differential)
        4. RECOMMENDATION (urgent/routine follow-up, CT if warranted)
    """),

    "breast_density_classification": textwrap.dedent("""\
        You are a breast imaging radiologist AI assistant. \
        The following is from an automated mammography breast density classification.

        Model: Breast Density Classification
        Modality: Mammography
        Timestamp: {timestamp}

        Classification result:
        {findings}

        Report structure:
        1. TECHNIQUE
        2. BREAST COMPOSITION (ACR density category A-D with justification)
        3. FINDINGS (any incidental findings noted by the model)
        4. IMPRESSION
        5. RECOMMENDATION (screening interval, supplemental US/MRI for dense breasts)
    """),

    "pathology_tumor_detection": textwrap.dedent("""\
        You are a pathologist AI assistant. \
        The following is from an automated WSI (whole slide image) tumor detection.

        Model: Pathology Tumor Detection (TorchVision)
        Modality: Digital Pathology / WSI
        Timestamp: {timestamp}

        Detection results:
        {findings}

        Report structure:
        1. SPECIMEN TYPE / STAIN
        2. FINDINGS (tumor-positive regions, approximate extent)
        3. IMPRESSION (histological diagnosis if determinable, grade)
        4. RECOMMENDATION (IHC panel, molecular testing, MDT referral)
    """),
}


# ────────────────────────────────────────────────────────────
#  Findings extraction
# ────────────────────────────────────────────────────────────
def extract_findings_summary(data: dict[str, Any], model: str) -> str:
    """
    Convert a raw MONAI Label inference response dict into a human-readable
    text summary suitable for embedding in the LLM prompt.

    Handles multiple output formats depending on model type:

    - **CXR pathology** (TorchXRayVision): ``data["predictions"]`` contains
      per-pathology probability scores (0.0–1.0).  Scores ≥ 0.35 are flagged.
    - **Segmentation/detection bundles**: ``data["params"]`` contains raw
      inference metadata (label names, bounding boxes, latencies, etc.).
    - **Generic fallback**: dumps the raw JSON (truncated to 1200 chars).

    Parameters
    ----------
    data : dict
        Raw inference response parsed from JSON.
    model : str
        Model name (used for format detection heuristics).

    Returns
    -------
    str
        Multi-line text summary of the findings.
    """
    parts: list[str] = []

    # CXR pathology model (TorchXRayVision format)
    if "predictions" in data:
        preds = data["predictions"]
        parts.append("Pathology detection scores (0.0 – 1.0):")
        for k, v in sorted(preds.items(), key=lambda x: -x[1]):
            bar = "█" * int(v * 20)
            flag = " ⚠ FLAGGED" if v >= 0.35 else ""
            parts.append(f"  {k:<30}  {v:.3f}  {bar}{flag}")
        findings = data.get("findings", [])
        if findings:
            parts.append(f"\nFlagged findings (≥35% confidence): {', '.join(findings)}")
        parts.append(f"Overall: {'ABNORMAL' if data.get('abnormal') else 'Normal range'}")

    # Segmentation / detection bundles
    elif "params" in data:
        params = data["params"]
        parts.append("Inference parameters / metadata:")
        parts.append(json.dumps(params, indent=2)[:800])

    # Generic fallback
    if not parts:
        parts.append(json.dumps(data, indent=2)[:1200])

    return "\n".join(parts)


# ────────────────────────────────────────────────────────────
#  MONAI Label inference call
# ────────────────────────────────────────────────────────────
def run_inference(model: str, image_path: str) -> dict[str, Any]:
    """
    Submit an image to MONAI Label for inference and return the parsed result.

    Sends a ``POST /infer/{model}`` request with the image file as a
    multipart form upload.  The response is expected to be JSON (for
    this simplified path; the full multipart handling with NIfTI masks
    is done in ``process_findings.py``).

    Uses ``httpx`` if available (better timeout handling), otherwise
    falls back to ``urllib`` from the standard library.

    Parameters
    ----------
    model : str
        MONAI Label model name.
    image_path : str
        Path to a NIfTI file to submit.  For DICOM series, use the
        session-based workflow in ``run-inference.sh`` instead.

    Returns
    -------
    dict
        Parsed JSON response from MONAI Label.

    Raises
    ------
    FileNotFoundError
        If ``image_path`` does not exist.
    httpx.HTTPStatusError / urllib.error.HTTPError
        On non-2xx server responses.
    """
    path = Path(image_path)
    if not path.exists():
        raise FileNotFoundError(f"Image not found: {image_path}")

    url = f"{ML_BASE_URL}/infer/{model}"
    print(f"[inference] POST {url}  file={path.name}", flush=True)

    if _HTTP == "httpx":
        import httpx
        with httpx.Client(timeout=300) as client:
            with open(path, "rb") as fh:
                resp = client.post(
                    url,
                    files={"file": (path.name, fh, "application/octet-stream")},
                    data={"params": json.dumps({"result_extension": ".nii.gz"})},
                )
        resp.raise_for_status()
        return resp.json()
    else:
        import urllib.request
        import urllib.parse
        # Simple multipart with urllib (basic)
        boundary = "----MonaiBoundary1234"
        with open(path, "rb") as fh:
            file_data = fh.read()
        body = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="params"\r\n\r\n'
            f'{{"result_extension":".nii.gz"}}\r\n'
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{path.name}"\r\n'
            f"Content-Type: application/octet-stream\r\n\r\n"
        ).encode() + file_data + f"\r\n--{boundary}--\r\n".encode()
        req = urllib.request.Request(
            url,
            data=body,
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Accept": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=300) as resp:
            return json.loads(resp.read())


# ────────────────────────────────────────────────────────────
#  LLM report generation
# ────────────────────────────────────────────────────────────
def generate_report(model: str, findings_json: dict[str, Any]) -> str:
    """
    Send structured findings to the LLM and return the generated radiology report.

    1. Selects a model-specific prompt template (or uses the generic default).
    2. Fills in the template with the findings summary text.
    3. Sends the prompt to LM Studio's OpenAI-compatible
       ``/v1/chat/completions`` endpoint.
    4. Returns the generated report text, or an error message with the
       raw findings if the LLM is unreachable.

    Parameters
    ----------
    model : str
        MONAI Label model name (used to select the prompt template).
    findings_json : dict
        Raw inference response dictionary.

    Returns
    -------
    str
        Generated radiology report text.
    """
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    findings_text = extract_findings_summary(findings_json, model)

    template = REPORT_TEMPLATES.get(model, REPORT_TEMPLATES["default"])
    prompt = template.format(
        model=model,
        timestamp=timestamp,
        findings=findings_text,
    )

    print(f"[llm] Calling {LLM_BASE_URL}/v1/chat/completions  model={LLM_MODEL}", flush=True)

    payload = json.dumps({
        "model": LLM_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": LLM_MAX_TOK,
        "temperature": LLM_TEMP,
        "stream": False,
    }).encode("utf-8")

    try:
        if _HTTP == "httpx":
            import httpx
            with httpx.Client(timeout=120) as client:
                resp = client.post(
                    f"{LLM_BASE_URL}/v1/chat/completions",
                    content=payload,
                    headers={"Content-Type": "application/json"},
                )
            resp.raise_for_status()
            result = resp.json()
        else:
            import urllib.request
            req = urllib.request.Request(
                f"{LLM_BASE_URL}/v1/chat/completions",
                data=payload,
                headers={"Content-Type": "application/json", "Accept": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=120) as resp:
                result = json.loads(resp.read())

        return result["choices"][0]["message"]["content"]

    except Exception as exc:
        return (
            f"[Report generation failed — LM Studio not reachable at {LLM_BASE_URL}]\n"
            f"Error: {exc}\n\n"
            f"--- Raw findings summary ---\n{findings_text}"
        )


# ────────────────────────────────────────────────────────────
#  CLI
# ────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate radiology reports from MONAI inference results via LLM"
    )
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--findings", metavar="JSON_FILE",
                     help="Path to saved MONAI Label inference JSON file")
    src.add_argument("--stdin", action="store_true",
                     help="Read inference JSON from stdin")
    src.add_argument("--image", metavar="PATH",
                     help="Run inference on this image file (requires --model)")

    parser.add_argument("--model", default="",
                        help="MONAI Label model name (required with --image)")
    parser.add_argument("--no-llm", action="store_true",
                        help="Print findings summary only, skip LLM call")
    parser.add_argument("--out", metavar="FILE",
                        help="Save report to file")

    args = parser.parse_args()

    findings_data: dict[str, Any] = {}

    if args.findings:
        with open(args.findings) as f:
            findings_data = json.load(f)
        model = args.model or "default"

    elif args.stdin:
        findings_data = json.load(sys.stdin)
        model = args.model or "default"

    elif args.image:
        if not args.model:
            parser.error("--image requires --model")
        model = args.model
        print(f"[inference] Running {model} on {args.image} ...", flush=True)
        findings_data = run_inference(model, args.image)
        print("[inference] Complete\n", flush=True)

    else:
        parser.print_help()
        sys.exit(1)

    # Print raw findings
    print("=" * 60)
    print("FINDINGS SUMMARY")
    print("=" * 60)
    print(extract_findings_summary(findings_data, model))
    print()

    if args.no_llm:
        return

    # Generate + print report
    print("=" * 60)
    print("GENERATED RADIOLOGY REPORT")
    print("=" * 60)
    report = generate_report(model, findings_data)
    print(report)
    print()

    if args.out:
        Path(args.out).write_text(report)
        print(f"[saved] Report written to: {args.out}")


if __name__ == "__main__":
    main()
