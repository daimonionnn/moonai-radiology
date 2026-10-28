#!/usr/bin/env python3
"""
process_findings.py — Post-process MONAI Label multipart inference response.

Pipeline
--------
1. Parse the raw multipart/form-data response body:
   - Extract the 'params' JSON part (label_names, boxes, centroids, latencies)
   - Extract the 'image' binary part (NIfTI segmentation mask)

2. Resolve label names (integer → name) in priority order:
   a. params["label_names"] from the inference response  (most authoritative)
   b. GET /info/ from the MONAI Label server             (fallback if absent)
   c. "structure_N"                                       (last resort)

3. Extract original image metadata:
   - Load DICOM tags or NIfTI header to ascertain true pixel spacing
   - Original Δx, Δy, Δz vs output masked tensor resolution.

4. Load NIfTI mask with nibabel:
   - img.header.get_zooms()[:3] → voxel spacing in mm (same as sitk.GetSpacing())
   - np.asarray(img.dataobj)    → label array         (same as sitk.GetArrayFromImage())
   - voxel_volume_cm3 = Δx * Δy * Δz / 1000
   - per-label voxel count × voxel_volume_cm3 → cm³/mL
   - Alert LLM to any physical spacing divergences (downsampling/inflation) > 1%

5. Format detection boxes and classification scores.

6. Print structured clinical summary for the LLM.

Usage:
    python3 scripts/inference/process_findings.py \\
        --tmpfile /tmp/monai_infer_XXXXX \\
        --model   wholeBody_ct_segmentation \\
        --image   datasets/ct/Patient/DICOM/series \\
        [--server http://localhost:8000]
"""

import sys
import os
import re
import json
import struct
import gzip
import tempfile
import argparse


# Default location of the downloaded MONAI Zoo bundles, relative to this script
# (scripts/inference/process_findings.py → ../models/bundles).
DEFAULT_BUNDLES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "models", "bundles",
)


# ── Reference volume ranges (cm³ ≡ mL) ───────────────────────────────────────
# INFORMATIONAL ONLY — not validated diagnostic thresholds. Organ volumes depend
# on body size, age and sex, and every source below has its own population and
# method, so a flag means "worth a look", never "abnormal". Have a radiologist
# review these before any clinical-style use. Keys match segmentation label names.
#
# Each entry: kind "range"   = observed range in healthy adults (flag: HIGH/LOW)
#             kind "p10-p90" = 10th–90th percentile of a clinical population;
#                              by definition 20 % of people fall outside it
#                              (flag: >p90 / <p10)
# "sex": {"M": (lo, hi), "F": (lo, hi)} or "all": (lo, hi). Unknown sex → widest.
#
# Sources
#   J-MID  Nationwide organ volume reference standards, abdominal CT, Japan
#          (medRxiv 10.64898/2026.01.30.26345246, Tables 3–4): TotalSegmentator
#          v2.10, n≈50 000 routine non-contrast CT, median age 67–71, mostly
#          5–7 mm slices — not a healthy cohort, smaller body size than Central
#          Europe.
#   Prassopoulos 1997, Eur Radiol (10.1007/s003300050145): spleen, CT, n=140,
#          Greek adults, no significant sex/size effect.
#   Stefanovic 2012, Surg Radiol Anat (ResearchGate 51868120): pancreas, CT,
#          n=220, Serbian adults.
#   Kim 2021 (ResearchGate 353976705): population-based reference interval for
#          liver volume in healthy adults, CT, Korea.
REFERENCE_RANGES: dict[str, dict] = {
    "liver":        {"kind": "range", "all": (824.5, 1700.0), "source": "Kim 2021"},
    "spleen":       {"kind": "range", "all": (107.2, 314.5), "source": "Prassopoulos 1997"},
    "pancreas":     {"kind": "range", "all": (37.4, 168.2), "source": "Stefanovic 2012"},
    "kidney_left":  {"kind": "p10-p90", "M": (83.1, 192.3), "F": (73.2, 158.1), "source": "J-MID"},
    "kidney_right": {"kind": "p10-p90", "M": (85.5, 187.4), "F": (72.6, 151.5), "source": "J-MID"},
}

# Structures whose volume is known to be unreliable between engines: on the same
# CT, MONAI wholeBody gave pancreas 92 mL vs TotalSegmentator 132 mL (see
# docs/REVIEW_AND_TODO.md §1c). Printed next to any flag so it is not over-read.
CAVEATS: dict[str, str] = {
    "pancreas": "boundaries are hard to segment; engines disagree by up to ~40 % — check the mask",
}

# Spleen craniocaudal length (cm): above "borderline" = possible, above
# "definite" = splenomegaly by length (UT Southwestern US protocol). Length
# depends on height and sex (Chow 2016, Radiology 10.1148/radiol.2015150887).
SPLEEN_LENGTH_CM = {"M": (13.0, 14.0), "F": (12.0, 13.0)}


def reference_for(name: str, sex: str = "") -> tuple[float, float, dict] | None:
    """Return ``(lo, hi, entry)`` for a structure, choosing the sex-specific
    range when known and the widest one otherwise."""
    entry = REFERENCE_RANGES.get(name)
    if not entry:
        return None
    if "all" in entry:
        lo, hi = entry["all"]
    elif sex in ("M", "F"):
        lo, hi = entry[sex]
    else:
        lo, hi = min(entry["M"][0], entry["F"][0]), max(entry["M"][1], entry["F"][1])
    return lo, hi, entry


def flag_for(name: str, vol_cm3: float, sex: str = "") -> tuple[str, str]:
    """
    Compare a measured volume against ``REFERENCE_RANGES`` *in Python*.

    We deliberately compute flags here rather than letting the LLM decide —
    otherwise the model invents its own "normal ranges" (it once claimed a liver
    normal of 1200–1600 mL out of thin air). The LLM is only given the numbers
    plus the reference string produced here.

    Returns
    -------
    tuple[str, str]
        ``(flag, reference_str)`` — e.g. ``("⚠ HIGH", "107-315 Prassopoulos 1997")``,
        ``("↑ >p90", "83-192 J-MID p10-p90 M")`` or ``("", "-")`` when no
        reference is defined for the structure.
    """
    ref = reference_for(name, sex)
    if not ref:
        return "", "-"
    lo, hi, entry = ref
    pct = entry["kind"] == "p10-p90"
    ref_str = f"{lo:.0f}-{hi:.0f} {entry['source']}"
    if pct:
        ref_str += " p10-p90" + (f" {sex}" if sex in ("M", "F") else "")
    if vol_cm3 < lo:
        return ("↓ <p10" if pct else "⚠ LOW"), ref_str
    if vol_cm3 > hi:
        return ("↑ >p90" if pct else "⚠ HIGH"), ref_str
    return "✓", ref_str


def caveat_for(name: str) -> str:
    return CAVEATS.get(name, "")


def spleen_length_flag(length_cm: float, sex: str = "") -> str:
    """Flag the spleen's craniocaudal length; unknown sex uses the male limits
    (the more lenient ones), so a flag is never raised on sex alone."""
    borderline, definite = SPLEEN_LENGTH_CM.get(sex, SPLEEN_LENGTH_CM["M"])
    if length_cm > definite:
        return f"⚠ enlarged by length (> {definite:g} cm)"
    if length_cm > borderline:
        return f"⚠ borderline (> {borderline:g} cm)"
    return f"✓ (≤ {borderline:g} cm)"


def craniocaudal_length_cm(mask, affine) -> float:
    """Extent of a binary mask along the patient's head–feet (RAS S) axis, in cm."""
    import numpy as np
    idx = np.argwhere(mask)
    if not len(idx):
        return 0.0
    s = (affine[:3, :3] @ idx.T + affine[:3, 3:4])[2]
    return float(s.max() - s.min()) / 10.0


def get_patient_sex(image_path: str) -> str:
    """DICOM PatientSex (0010,0040) as "M"/"F", or "" for NIfTI / unknown."""
    try:
        if image_path and os.path.isdir(image_path):
            import pydicom
            for root, _, files in os.walk(image_path):
                for f in sorted(files):
                    if f.startswith("."):
                        continue
                    try:
                        dcm = pydicom.dcmread(os.path.join(root, f), stop_before_pixels=True)
                    except Exception:
                        continue
                    sex = str(getattr(dcm, "PatientSex", "") or "").strip().upper()
                    return sex if sex in ("M", "F") else ""
    except Exception:
        pass
    return ""


def load_labels_from_bundle_metadata(model: str, bundles_dir: str) -> dict:
    """
    Fallback: read label names from the bundle's own ``configs/metadata.json``.

    Some bundles (notably ``wholeBrainSeg_Large_UNEST_segmentation``) do NOT
    return a ``label_names`` map in the inference response, and the MONAI Label
    ``/info/`` endpoint may not expose one either — which leaves every structure
    named ``structure_N``. However, every MONAI Zoo bundle ships the mapping in::

        configs/metadata.json → network_data_format.outputs.pred.channel_def
            {"0": "background", "1": "3rd-Ventricle", "7": "Brain-Stem", ...}

    Parameters
    ----------
    model : str
        Bundle name (matches the sub-directory under ``bundles_dir``).
    bundles_dir : str
        Directory holding the extracted MONAI Zoo bundles.

    Returns
    -------
    dict
        ``{int: name}`` mapping (including background at 0), or ``{}`` on failure.
    """
    try:
        meta_path = os.path.join(bundles_dir, model, "configs", "metadata.json")
        if not os.path.exists(meta_path):
            return {}
        with open(meta_path) as f:
            meta = json.load(f)
        channel_def = (
            meta.get("network_data_format", {})
            .get("outputs", {})
            .get("pred", {})
            .get("channel_def", {})
        )
        if not channel_def:
            return {}
        return {int(k): v for k, v in channel_def.items() if str(k).lstrip("-").isdigit()}
    except Exception:
        return {}


def load_labels_from_server(model: str, server_url: str) -> dict:
    """
    Fallback: fetch label names from the MONAI Label server's /info/ endpoint.

    When the inference response itself does not include a ``label_names`` mapping
    (some older bundles omit it), we query the server's ``GET /info/`` endpoint
    which returns a JSON document listing all loaded models and their label
    definitions.

    Parameters
    ----------
    model : str
        Name of the MONAI Label model (e.g. ``wholeBody_ct_segmentation``).
    server_url : str
        Base URL of the MONAI Label server (e.g. ``http://localhost:8000``).

    Returns
    -------
    dict
        Mapping of integer label value → human-readable label name string.
        e.g. ``{1: 'liver', 2: 'spleen', ...}``
        Returns empty dict on any failure (network, parsing, missing model).
    """
    try:
        import urllib.request
        url = server_url.rstrip('/') + '/info/'
        with urllib.request.urlopen(url, timeout=5) as resp:
            info = json.load(resp)

        models = info.get('models', {})
        if model not in models:
            return {}

        model_info = models[model]

        # MONAI Label's /info/ response stores labels under the 'labels' key,
        # while the inference response uses 'label_names'. Check both.
        label_map = model_info.get('labels') or model_info.get('label_names') or {}
        if not label_map:
            return {}

        # MONAI Label convention: labels are stored as {name: int} (e.g.
        # {"liver": 1, "spleen": 2}). We need the inverse {int: name} for
        # lookup during volume computation.
        if all(isinstance(v, int) for v in label_map.values()):
            return {v: k for k, v in label_map.items()}

        # If already in {str(int): name} or {int: name} format, normalise keys
        # to int for consistent downstream lookup.
        return {int(k) if str(k).isdigit() else k: v for k, v in label_map.items()}
    except Exception:
        return {}

def extract_parts(raw_bytes: bytes) -> tuple[dict, bytes | None]:
    """
    Parse the multipart/form-data response from MONAI Label's ``POST /infer/``.

    MONAI Label returns inference results as a multipart/form-data HTTP response
    containing two named parts:

    - ``"params"``  — JSON text with label_names, bounding boxes, centroids,
      classification scores, and latency timings.
    - ``"image"``   — Binary NIfTI (.nii.gz) segmentation mask where each voxel
      is an integer label index (0 = background).

    The multipart boundary is auto-detected via regex since the raw response
    is saved to a temp file by curl (run-inference.sh) without HTTP headers.

    Parameters
    ----------
    raw_bytes : bytes
        Complete multipart/form-data response body read from the temp file.

    Returns
    -------
    tuple[dict, bytes | None]
        (params_dict, nifti_image_bytes) — image bytes are None if no binary
        image part was found or it was too small (<50 bytes) to be valid.
    """
    text = raw_bytes.decode("utf-8", errors="replace")

    # ── params JSON ──────────────────────────────────────────────────────
    # Match the "params" part header, skip optional Content-Type line,
    # then capture the JSON object up to the next multipart boundary.
    params = {}
    m = re.search(
        r'name="params"[^\r\n]*\r?\n(?:Content-Type:[^\r\n]*\r?\n)?\r?\n'
        r'(\{.*?\})(?:\r?\n--)',
        text,
        re.DOTALL,
    )
    if m:
        try:
            params = json.loads(m.group(1))
        except Exception:
            pass
    else:
        # Fallback: some models return plain JSON instead of multipart
        # (e.g. classification-only models with no segmentation mask).
        try:
            params = json.loads(text)
        except Exception:
            pass

    # ── image binary ─────────────────────────────────────────────────────
    # Search raw bytes (not decoded text) for the "image" part header.
    # The binary payload starts after the double CRLF following headers.
    img_bytes = None
    img_m = re.search(
        rb'name="image"[^\r\n]*\r?\nContent-Type:[^\r\n]*\r?\n\r?\n',
        raw_bytes,
    )
    if img_m is None:
        # Some servers omit the Content-Type header on the image part
        img_m = re.search(rb'name="image"[^\r\n]*\r?\n\r?\n', raw_bytes)

    if img_m:
        start = img_m.end()
        # Slice from the end of the image part header to the next boundary
        # marker ("\r\n--"). If no boundary is found, take everything.
        bnd = re.search(rb'\r?\n--', raw_bytes[start:])
        img_bytes = raw_bytes[start : start + bnd.start()] if bnd else raw_bytes[start:]
        # Sanity check: discard tiny payloads that can't be valid NIfTI
        if len(img_bytes) < 50:
            img_bytes = None

    return params, img_bytes


def is_nifti(data: bytes) -> bool:
    """
    Detect whether a byte buffer contains a NIfTI-1 or NIfTI-2 image.

    Checks for two cases:

    1. **Gzip-compressed** — first two bytes are ``0x1f 0x8b``. Attempts to
       partially decompress the header; if the gzip magic is present we
       assume it's a ``.nii.gz`` even if decompression of the first 512
       bytes fails (the file may simply be a large valid gzip stream).

    2. **Uncompressed** — reads the ``sizeof_hdr`` field from bytes 0–3
       (little-endian int32). NIfTI-1 headers are exactly 348 bytes;
       NIfTI-2 headers are 540 bytes.

    Parameters
    ----------
    data : bytes
        Raw image bytes (at least the first few hundred bytes are needed).

    Returns
    -------
    bool
        True if the data appears to be a valid NIfTI file.
    """
    if len(data) < 4:
        return False

    # Case 1: gzip-compressed NIfTI (.nii.gz)
    if data[:2] == b"\x1f\x8b":
        try:
            header = gzip.decompress(data[:512])
            return len(header) >= 4
        except Exception:
            # If gzip header is present but partial decompression fails,
            # assume it's a valid .nii.gz — the full file is likely intact.
            return True

    # Case 2: uncompressed NIfTI (.nii)
    # The sizeof_hdr field at byte offset 0 must be 348 (NIfTI-1) or 540 (NIfTI-2).
    sizeof_hdr = struct.unpack_from("<i", data, 0)[0]
    return sizeof_hdr in (348, 540)


def get_original_metadata(image_path: str):
    """
    Extract the **original** image dimensions and voxel spacing from the
    source data (DICOM series directory or NIfTI file) *before* any
    MONAI Label preprocessing/resampling.

    This is critical for detecting resampling mismatches: MONAI Label zoo
    models often resample the input to a fixed training resolution (e.g.
    1×1×1 mm isotropic) before inference, and the output segmentation mask
    inherits that resampled spacing — not the original acquisition spacing.
    By comparing the two, we can warn the user that reported volumes may
    be inaccurate.

    DICOM path
    ----------
    For a directory of DICOM slices, we read a single representative file
    (the first sorted by filename) and extract:

    - ``PixelSpacing`` (0028,0030) → in-plane Δx, Δy in mm
    - ``SpacingBetweenSlices`` (0018,0088) preferred, falls back to
      ``SliceThickness`` (0018,0050) → Δz in mm
    - ``Rows`` / ``Columns`` → matrix size; slice count = number of files

    NIfTI path
    ----------
    For a ``.nii`` or ``.nii.gz`` file, we read the header's ``zooms``
    (``pixdim[1:4]``) and ``shape``.

    Parameters
    ----------
    image_path : str
        Path to DICOM series directory or NIfTI file.

    Returns
    -------
    tuple[tuple | None, tuple | None]
        ``(shape, zooms)`` where shape is ``(rows, cols, slices)`` and
        zooms is ``(Δx_mm, Δy_mm, Δz_mm)``. Both are None on failure.
    """
    import os
    if not image_path or not os.path.exists(image_path):
        return None, None
    try:
        if os.path.isdir(image_path):
            # ── DICOM series directory ───────────────────────────────────
            import pydicom
            # List only real files (skip hidden/macOS resource forks)
            files = sorted([f for f in os.listdir(image_path) if not f.startswith(".")])
            if not files:
                return None, None

            # Read only the header (stop_before_pixels=True) to save time
            dcm = pydicom.dcmread(os.path.join(image_path, files[0]), stop_before_pixels=True)

            # In-plane pixel spacing: [row_spacing, col_spacing] in mm
            ps = getattr(dcm, "PixelSpacing", [1.0, 1.0])

            # Through-plane spacing: prefer SpacingBetweenSlices (actual
            # distance between slice centres) over SliceThickness (nominal
            # acquired thickness, which may differ for overlapping slices).
            try:
                st = getattr(dcm, "SpacingBetweenSlices", getattr(dcm, "SliceThickness", 1.0))
            except Exception:
                st = 1.0

            # Voxel spacing is a physical distance and must be positive. Some
            # scanners store SpacingBetweenSlices as a *signed* value encoding
            # the slice-ordering direction (e.g. -1.25 mm). Taking abs() here
            # prevents a false "resampling mismatch" warning and a negative
            # voxel volume downstream.
            zooms = (abs(float(ps[0])), abs(float(ps[1])), abs(float(st)))
            shape = (int(getattr(dcm, "Rows", 0)), int(getattr(dcm, "Columns", 0)), len(files))
            return shape, zooms
        else:
            # ── NIfTI file (.nii / .nii.gz) ─────────────────────────────
            import nibabel as nib
            img = nib.load(image_path)
            zooms = tuple(float(x) for x in img.header.get_zooms()[:3])
            return img.shape, zooms
    except Exception:
        return None, None


def get_modality(image_path: str) -> str:
    """
    Read the true imaging modality (CT, MR, MG, CR/DX, …) from the source data.

    The LLM otherwise *guesses* the modality from the model name and gets it
    wrong (e.g. it labelled a brain **MRI** report as "CT scan"). Passing the
    real DICOM ``Modality`` (0008,0060) tag into the report fixes that.

    Returns an empty string for NIfTI inputs (no modality tag) or on failure.
    """
    try:
        if image_path and os.path.isdir(image_path):
            import pydicom
            for root, _, files in os.walk(image_path):   # series may sit in subfolders
                for f in sorted(files):
                    if f.startswith("."):
                        continue
                    try:
                        dcm = pydicom.dcmread(os.path.join(root, f), stop_before_pixels=True)
                    except Exception:
                        continue
                    return str(getattr(dcm, "Modality", "") or "").strip()
    except Exception:
        pass
    return ""


def spleen_length_from_mask(nifti_bytes: bytes, label_names: dict) -> float:
    """Craniocaudal spleen length (cm) from a multi-label mask, or 0.0."""
    idx = next((int(k) for k, v in label_names.items() if str(v) == "spleen"), None)
    if idx is None:
        idx = next((int(v) for k, v in label_names.items() if str(k) == "spleen"), None)
    if idx is None:
        return 0.0
    import nibabel as nib
    import numpy as np
    with tempfile.NamedTemporaryFile(suffix=".nii.gz", delete=False) as tf:
        tf.write(nifti_bytes)
        tmp_path = tf.name
    try:
        img = nib.load(tmp_path)
        return craniocaudal_length_cm(np.asarray(img.dataobj) == idx, img.affine)
    except Exception:
        return 0.0
    finally:
        os.unlink(tmp_path)


def compute_volumes(nifti_bytes: bytes, label_names: dict) -> list[tuple[str, float, float]]:
    """
    Compute per-structure anatomical volumes from a NIfTI segmentation mask.

    The mask is a 3D integer array where each non-zero value represents a
    distinct anatomical label (e.g. 1 = liver, 2 = spleen). This function:

    1. Writes the raw NIfTI bytes to a temp file (nibabel requires a path).
    2. Reads the voxel spacing from the NIfTI header (``pixdim[1:4]``).
    3. Computes ``voxel_volume_cm³ = Δx_mm × Δy_mm × Δz_mm / 1000``.
    4. Counts voxels per label and multiplies by ``voxel_volume_cm³``.
    5. Resolves integer label indices to human-readable names.

    .. note::
        The spacing in the output mask header reflects MONAI Label's
        internal resampling, **not** the original acquisition spacing.
        The caller (``main()``) compares these against the original
        metadata from ``get_original_metadata()`` to flag discrepancies.

    Parameters
    ----------
    nifti_bytes : bytes
        Complete ``.nii.gz`` file contents (the ``"image"`` part of the
        multipart inference response).
    label_names : dict
        Mapping of label index → name.  Accepts both ``{int: str}``
        and ``{str(int): str}`` key formats for flexibility.

    Returns
    -------
    tuple[list[tuple[str, float, float]], np.ndarray, tuple]
        - ``volumes`` — sorted list of ``(label_name, vol_cm3, vol_ml)``
          in descending order of volume.  cm³ ≡ mL for soft tissue.
        - ``zooms`` — the output mask's voxel spacing ``[Δx, Δy, Δz]``.
        - ``shape`` — the 3D array dimensions of the mask.
    """
    import nibabel as nib
    import numpy as np

    # nibabel requires a filesystem path; write bytes to a temp file.
    with tempfile.NamedTemporaryFile(suffix=".nii.gz", delete=False) as tf:
        tf.write(nifti_bytes)
        tmp_path = tf.name
    try:
        img = nib.load(tmp_path)
        data = np.asarray(img.dataobj, dtype=np.float32)

        # Voxel spacing in mm (same semantics as SimpleITK's GetSpacing())
        zooms = np.array(img.header.get_zooms()[:3], dtype=float)

        # Convert mm³ → cm³:  1 cm³ = 1000 mm³
        voxel_vol_cm3 = float(zooms[0] * zooms[1] * zooms[2]) / 1000.0

        # Find all non-background labels (label 0 is always background)
        unique = [int(v) for v in np.unique(data) if v > 0]
        volumes = []
        for lv in unique:
            n = int(np.sum(data == lv))
            if n == 0:
                continue
            vol = n * voxel_vol_cm3

            # Resolve label index → human-readable name.
            # Try string key first (JSON keys are always strings), then int.
            name = (
                label_names.get(str(lv))
                or label_names.get(lv)
                or f"structure_{lv}"
            )
            # cm³ = mL for water-density soft tissue (density ≈ 1.0 g/cm³)
            volumes.append((str(name), vol, vol))

        # Sort largest structures first for clinical readability
        volumes.sort(key=lambda x: -x[1])
        return volumes, zooms, data.shape
    finally:
        # Always clean up the temp file, even on exceptions
        os.unlink(tmp_path)



def format_detection(params: dict) -> list[str]:
    """
    Format detection model output (bounding boxes or centroids) into
    human-readable summary lines for the LLM report.

    MONAI Label detection models (e.g. ``lung_nodule_ct_detection``) return
    results in one of two formats:

    **Bounding boxes** (RetinaNet-style)::

        params["box"]   = [[x1, y1, z1, x2, y2, z2], ...]
        params["label"] = ["nodule", ...]
        params["score"] = [0.87, ...]

    Box coordinates are in voxel space.  We compute the centroid as the
    midpoint ``((x1+x2)/2, ...)`` and the extent as ``|x2-x1| × |y2-y1| × |z2-z1|``.

    **Centroids** (point-based models)::

        params["centroids"] = {"label_name": [[x, y, z], ...], ...}

    Parameters
    ----------
    params : dict
        Parsed ``params`` JSON from the inference response.

    Returns
    -------
    list[str]
        Formatted lines ready for printing or embedding in the LLM prompt.
    """
    lines = []
    boxes     = params.get("box", [])
    labels    = params.get("label", [])
    centroids = params.get("centroids", {})
    scores    = params.get("score", params.get("scores", []))

    # Is this a detection response at all? MONAI Label detection models include
    # the "box"/"label" keys (possibly empty) even when nothing is found. We use
    # that to emit an explicit "0 findings" line instead of silently printing
    # nothing (which previously made a negative scan look like a failed run).
    is_detection = ("box" in params) or bool(centroids)
    if not is_detection:
        return lines

    # Coordinate space: MONAI Label's detection post-processing applies
    # AffineBoxToWorldCoordinated, so boxes come back in WORLD millimetres
    # (patient space) as [x1, y1, z1, x2, y2, z2] — NOT voxel indices.
    if boxes:
        lines.append(f"Detection: {len(boxes)} finding(s)")
        for i, box in enumerate(boxes):
            lbl = labels[i] if i < len(labels) else f"finding_{i+1}"
            sc  = f"  confidence={scores[i]:.3f}" if i < len(scores) else ""
            try:
                cx, cy, cz = (box[0]+box[3])/2, (box[1]+box[4])/2, (box[2]+box[5])/2
                sx, sy, sz = abs(box[3]-box[0]), abs(box[4]-box[1]), abs(box[5]-box[2])
                diam = max(sx, sy, sz)   # long-axis diameter — the clinically reported size
                lines.append(
                    f"  #{i+1} label={lbl}  "
                    f"centroid=({cx:.1f},{cy:.1f},{cz:.1f}) mm  "
                    f"size=({sx:.1f}×{sy:.1f}×{sz:.1f}) mm  "
                    f"max_diameter={diam:.1f} mm{sc}"
                )
            except Exception:
                lines.append(f"  #{i+1} label={lbl}  box={box}{sc}")

    elif centroids:
        # Centroid-based output: dict of label → list of [x,y,z] points
        total = sum(len(v) if isinstance(v, list) else 1 for v in centroids.values())
        lines.append(f"Detection: {total} location(s) found")
        for lbl, pts in centroids.items():
            if isinstance(pts, list):
                for j, pt in enumerate(pts):
                    lines.append(f"  {lbl} #{j+1}: {pt}")
            else:
                lines.append(f"  {lbl}: {pts}")

    else:
        # Detection model ran but returned nothing.
        lines.append("Detection: 0 findings — no lesions detected above the model's confidence threshold.")

    return lines


def format_classification(params: dict) -> list[str]:
    """
    Format classification predictions into a tabular summary.

    Classification models (e.g. ``breast_density_classification``,
    ``cxr_pathology`` via TorchXRayVision) return per-class probability
    scores in ``params["predictions"]`` as ``{class_name: float, ...}``.

    Scores are displayed as percentages, sorted highest-first.  Any class
    with probability ≥ 50% is flagged as POSITIVE and collected into a
    summary line for the LLM to highlight in the report.

    Parameters
    ----------
    params : dict
        Parsed ``params`` JSON from the inference response.

    Returns
    -------
    list[str]
        Formatted classification table lines.
    """
    lines = []
    # Some models use "predictions", others "prediction" — check both
    predictions = params.get("predictions", params.get("prediction", {}))
    if not isinstance(predictions, dict):
        return lines

    # Sort by probability descending so clinically significant findings
    # appear first
    sorted_preds = sorted(
        predictions.items(),
        key=lambda x: -float(x[1]) if isinstance(x[1], (int, float)) else 0,
    )
    lines.append("Classification predictions:")
    positives = []
    for k, v in sorted_preds:
        if isinstance(v, (int, float)):
            pct = float(v) * 100
            # Threshold: ≥ 50% is considered a positive finding
            flag_str = "  ← POSITIVE" if float(v) >= 0.5 else ""
            lines.append(f"  {k:<42} {pct:>5.1f}%{flag_str}")
            if float(v) >= 0.5:
                positives.append(f"{k} ({pct:.1f}%)")
    if positives:
        lines.append("")
        lines.append(f"  Flagged positive: {', '.join(positives)}")
    return lines


def main():
    """
    CLI entry point — orchestrates the full post-processing pipeline.

    1. Read the raw multipart response dumped by ``run-inference.sh``.
    2. Parse params JSON + NIfTI mask via ``extract_parts()``.
    3. Resolve label names (response → server /info/ → fallback).
    4. Extract original image metadata for resampling comparison.
    5. Compute per-structure volumes and format the clinical summary.
    6. Print the complete report to stdout (consumed by the shell script
       and passed to the LLM as context for report generation).
    """
    parser = argparse.ArgumentParser(
        description="Post-process MONAI Label inference response into a clinical summary."
    )
    parser.add_argument("--tmpfile",  required=True,
                        help="Path to raw multipart response file from curl")
    parser.add_argument("--model",    default="unknown",
                        help="MONAI Label model name (for label lookups)")
    parser.add_argument("--image",    default="",
                        help="Original image path (DICOM dir or NIfTI) for metadata extraction")
    parser.add_argument("--server",   default="http://localhost:8000",
                        help="MONAI Label server URL for label name fallback")
    parser.add_argument("--bundles-dir", default=DEFAULT_BUNDLES_DIR,
                        help="Directory of MONAI Zoo bundles (for metadata.json label fallback)")
    args = parser.parse_args()

    # ── Step 1: Read raw multipart response body ─────────────────────────
    raw = open(args.tmpfile, "rb").read()
    params, img_bytes = extract_parts(raw)

    # ── Step 2: Resolve label names ─────────────────────────────────────
    # The inference response may include label_names in either direction:
    #   {"liver": 1, "spleen": 2}  (name→int, MONAI Label convention)
    #   {"1": "liver", "2": "spleen"}  (int→name)
    # Normalise to {int → name} for consistent lookup during volume computation.
    label_names_raw = params.get("label_names", {})

    def _invert_if_needed(d: dict) -> dict:
        """Ensure label map is always {int: str} regardless of source format."""
        if not d:
            return d
        if all(isinstance(v, int) for v in d.values()):
            return {v: k for k, v in d.items()}
        return {int(k) if str(k).isdigit() else k: v for k, v in d.items()}

    label_names = _invert_if_needed(label_names_raw)

    # Fallback chain for label names when the inference response omits them:
    #   1. GET /info/ from the MONAI Label server
    #   2. the bundle's own configs/metadata.json (works offline, and covers
    #      wholeBrainSeg which exposes no label_names any other way)
    if not label_names:
        label_names = load_labels_from_server(args.model, args.server)
    if not label_names:
        label_names = load_labels_from_bundle_metadata(args.model, args.bundles_dir)

    latencies = params.get("latencies", {})

    lines = []

    # ── Step 3: Extract original image metadata ─────────────────────────
    # Read the source DICOM/NIfTI metadata so we can detect resampling.
    orig_shape, orig_zooms = get_original_metadata(args.image)

    # ── Build output report ─────────────────────────────────────────────
    # ── Header ────────────────────────────────────────────────────────────
    modality = get_modality(args.image)
    sex = get_patient_sex(args.image)

    lines.append(f"AI Inference Report")
    lines.append(f"Model      : {args.model}")
    if modality:
        lines.append(f"Modality   : {modality}   (from DICOM tag — use this, do NOT infer modality)")
    if sex:
        lines.append(f"Sex        : {sex}   (from DICOM tag; used for sex-specific references)")
    lines.append(f"Source     : {args.image}")

    if orig_zooms:
        lines.append(
            f"Original   : size {orig_shape[0]}×{orig_shape[1]}×{orig_shape[2]} vox, "
            f"spacing {orig_zooms[0]:.2f}×{orig_zooms[1]:.2f}×{orig_zooms[2]:.2f} mm"
        )

    lines.append("")

    # ── Segmentation volumes ──────────────────────────────────────────────
    if img_bytes and is_nifti(img_bytes):
        try:
            volumes, zooms, shape = compute_volumes(img_bytes, label_names)
            if volumes:
                lines.append(
                    f"Segmentation: {len(volumes)} structures identified  "
                    f"(voxel size {zooms[0]:.2f}×{zooms[1]:.2f}×{zooms[2]:.2f} mm, "
                    f"volume {shape[0]}×{shape[1]}×{shape[2]} vox)"
                )
                
                # ── Resampling / spacing mismatch detection ──────────────
                # Compare the output mask's voxel spacing against the original
                # acquisition spacing.  MONAI Label zoo models typically resample
                # inputs to a fixed isotropic resolution (e.g. 1×1×1 mm) before
                # inference.  If the output spacing differs by >1% from the
                # original, the volume numbers will be physically misleading.
                if orig_zooms:
                    import math
                    spacing_mismatch = any(
                        not math.isclose(oz, z, rel_tol=1e-2, abs_tol=1e-3)
                        for oz, z in zip(orig_zooms, zooms)
                    )
                    if spacing_mismatch:
                        lines.append(
                            f"  [WARNING] Output mask spacing "
                            f"({zooms[0]:.2f}×{zooms[1]:.2f}×{zooms[2]:.2f}) "
                            f"differs from original image "
                            f"({orig_zooms[0]:.2f}×{orig_zooms[1]:.2f}×{orig_zooms[2]:.2f})."
                        )
                        lines.append(
                            f"            Volumes below are based on the "
                            f"resampled spacing, and may contain inaccuracies."
                        )
                
                lines.append("")
                lines.append(f"  {'Structure':<45} {'Volume (cm³/mL)':>16}  {'Ref (cm³)':>12}  Flag")
                lines.append(f"  {'─'*45} {'─'*16}  {'─'*12}  {'─'*8}")
                flagged = []
                for name, vol, _ in volumes:
                    flag, ref = flag_for(name, vol, sex)
                    lines.append(f"  {name:<45} {vol:>12.1f} cm³  {ref:>12}  {flag}")
                    if flag and flag != "✓":
                        note = f"; caveat: {caveat_for(name)}" if caveat_for(name) else ""
                        flagged.append(f"{name} {vol:.0f} cm³ ({flag.strip()}, ref {ref}{note})")
                spleen_cm = spleen_length_from_mask(img_bytes, label_names)
                if spleen_cm:
                    lines.append(f"  Spleen craniocaudal length: {spleen_cm:.1f} cm  "
                                 f"{spleen_length_flag(spleen_cm, sex)}")
                lines.append("")
                total = sum(v for _, v, _ in volumes)
                lines.append(f"  Total segmented volume: {total:.1f} cm³")
                if flagged:
                    lines.append(f"  Outside reference range: {'; '.join(flagged)}")
                lines.append(
                    "  NOTE: references are informational, from the cited studies "
                    "(see REFERENCE_RANGES); 'p10-p90' flags 20 % of a normal population "
                    "by definition; 'Ref = -' means no reference is defined — do NOT "
                    "infer normality for those structures."
                )
            else:
                lines.append("Segmentation: mask generated but no labelled voxels found.")
        except Exception as e:
            lines.append(f"Segmentation mask saved but volume computation failed: {e}")
            lines.append("  (Ensure nibabel and numpy are installed: python3 -m pip install nibabel)")

    elif img_bytes and "box" not in params:
        # (Detection responses echo a non-mask image; don't mislabel it as a mask.)
        lines.append("Segmentation: binary mask present (non-NIfTI format — volume analysis skipped).")

    # ── Detection ─────────────────────────────────────────────────────────
    det_lines = format_detection(params)
    if det_lines:
        lines.extend(det_lines)
        lines.append("")

    # ── Classification ────────────────────────────────────────────────────
    cls_lines = format_classification(params)
    if cls_lines:
        lines.extend(cls_lines)
        lines.append("")

    # ── No findings ───────────────────────────────────────────────────────
    # Only dump raw params when we genuinely produced no structured output
    # (no mask, no detection lines, no classification lines). A detection model
    # that legitimately found nothing still yields det_lines, so it won't fall here.
    if not img_bytes and not det_lines and not cls_lines:
        lines.append("Note: No structured output extracted. Raw params:")
        lines.append(json.dumps(params, indent=2)[:800])

    # ── Latencies ─────────────────────────────────────────────────────────
    if latencies:
        lines.append(
            f"Processing time: "
            f"pre={latencies.get('pre', 0):.1f}s  "
            f"infer={latencies.get('infer', 0):.1f}s  "
            f"total={latencies.get('total', 0):.1f}s"
        )

    print("\n".join(lines))


if __name__ == "__main__":
    main()
