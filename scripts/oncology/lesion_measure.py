#!/usr/bin/env python3
"""
Click-to-measure a CT lesion with ULS+ (universal lesion segmentation, Radboud).

    python lesion_measure.py <ct.nii.gz> --point=x,y,z [--voxel] --out <dir> [--label name]

--point is a world coordinate in mm (RAS, as 3D Slicer shows it) or, with --voxel,
a voxel index i,j,k of the NIfTI. A volume of interest (VOI) of 128×256×256 voxels
(z, y, x — the ULS23 convention) centred on the point is cropped, segmented by ULS+
(nnU-Net v2), and pasted back. The connected component at (or nearest to) the point
is kept and measured:

  volume (mL), RECIST-style axial long axis and the longest perpendicular short axis
  (on the axial slice with the longest diameter), centre and extent.

Writes <out>/<label>_mask.nii.gz (full CT grid) and <out>/<label>.json.
ULS+ segments only the lesion you point at — it is not a detector.

Model: models/uls_plus/ (weights from huggingface.co/nielsRocholl/ULS_plus; licence
stated inconsistently — CC BY-NC-SA 4.0 on Hugging Face, CC BY-SA 4.0 on Zenodo —
treat as non-commercial research only). Research use only, not a medical device.
"""
import argparse
import json
import os
import sys
import tempfile

import numpy as np
import SimpleITK as sitk
from scipy import ndimage as ndi
from scipy.spatial import ConvexHull

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODEL_ROOT = os.path.join(PROJECT_ROOT, "models", "uls_plus")
VOI_ZYX = (128, 256, 256)
PAD_HU = -1024


def crop_voi(img: sitk.Image, center_ijk):
    """VOI of VOI_ZYX voxels centred on center_ijk (i,j,k = x,y,z), padded with air."""
    size_xyz = (VOI_ZYX[2], VOI_ZYX[1], VOI_ZYX[0])
    start = [int(round(c - s / 2)) for c, s in zip(center_ijk, size_xyz)]
    lo_pad = [max(0, -s) for s in start]
    hi_pad = [max(0, s + n - d) for s, n, d in zip(start, size_xyz, img.GetSize())]
    padded = sitk.ConstantPad(img, lo_pad, hi_pad, PAD_HU)
    start_p = [s + p for s, p in zip(start, lo_pad)]
    voi = sitk.RegionOfInterest(padded, size_xyz, start_p)
    return voi


def _no_resampling(data, *args, **kwargs):
    """ULS+ plans name a custom 'no_resampling_data_or_seg_to_shape' function (shipped in
    the ULS+ repository) that returns the data unchanged: the model works on the VOI at
    its native spacing. Registered at runtime instead of patching nnU-Net on disk."""
    return data


def run_uls(voi: sitk.Image) -> sitk.Image:
    import torch
    from nnunetv2.utilities.plans_handling import plans_handler
    orig = plans_handler.recursive_find_resampling_fn_by_name
    plans_handler.recursive_find_resampling_fn_by_name = (
        lambda name: _no_resampling if name == "no_resampling_data_or_seg_to_shape" else orig(name))
    from nnunetv2.inference.predict_from_raw_data import nnUNetPredictor
    from nnunetv2.imageio.simpleitk_reader_writer import SimpleITKIO

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    pred = nnUNetPredictor(tile_step_size=0.5, use_gaussian=True, use_mirroring=True,
                           device=device, verbose=False, verbose_preprocessing=False,
                           allow_tqdm=False)
    pred.initialize_from_trained_model_folder(
        os.path.join(MODEL_ROOT, "Dataset090_ULS23_Combined",
                     "nnUNetTrainer__nnUNetResEncUNetLPlans__3d_fullres"),
        use_folds=("all",), checkpoint_name="checkpoint_final.pth")
    with tempfile.TemporaryDirectory() as tmp:
        f = os.path.join(tmp, "voi_0000.nii.gz")
        sitk.WriteImage(voi, f)
        arr, props = SimpleITKIO().read_images([f])
    seg = pred.predict_single_npy_array(arr, props, None, None, False)
    out = sitk.GetImageFromArray(seg.astype(np.uint8))
    out.CopyInformation(voi)
    return out


def axial_axes_mm(mask_zyx: np.ndarray, spacing_xyz) -> tuple[float, float, int]:
    """RECIST: longest in-plane diameter over axial slices, and the longest diameter
    perpendicular to it on that slice. Returns (long, short, slice index z)."""
    sx, sy = spacing_xyz[0], spacing_xyz[1]
    best = (0.0, 0.0, -1)
    for z in np.nonzero(mask_zyx.any(axis=(1, 2)))[0]:
        yx = np.argwhere(mask_zyx[z])
        pts = np.c_[yx[:, 1] * sx, yx[:, 0] * sy]
        if len(pts) >= 3:
            try:
                pts = pts[ConvexHull(pts).vertices]
            except Exception:
                pass
        d = np.linalg.norm(pts[:, None] - pts[None], axis=-1)
        i, j = np.unravel_index(np.argmax(d), d.shape)
        long_ = d[i, j]
        if long_ <= best[0]:
            continue
        axis = (pts[j] - pts[i]) / (long_ or 1)
        perp = np.array([-axis[1], axis[0]])
        proj = pts @ perp
        best = (float(long_ + max(sx, sy)), float(proj.max() - proj.min() + max(sx, sy)), int(z))
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ct")
    ap.add_argument("--point", required=True, help="x,y,z world mm (RAS) or voxel i,j,k with --voxel")
    ap.add_argument("--voxel", action="store_true")
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", default="lesion")
    a = ap.parse_args()

    img = sitk.ReadImage(a.ct)
    p = [float(v) for v in a.point.split(",")]
    if a.voxel:
        ijk = [int(round(v)) for v in p]
    else:
        lps = (-p[0], -p[1], p[2])                       # Slicer RAS → ITK LPS
        ijk = list(img.TransformPhysicalPointToIndex(lps))
    if not all(0 <= c < s for c, s in zip(ijk, img.GetSize())):
        sys.exit(f"point {a.point} is outside the image")

    voi = crop_voi(img, ijk)
    pred_voi = run_uls(voi)
    full = sitk.Resample(pred_voi, img, sitk.Transform(), sitk.sitkNearestNeighbor, 0)
    m = sitk.GetArrayFromImage(full) > 0                 # z, y, x

    lab, n = ndi.label(m, structure=np.ones((3, 3, 3)))
    click_zyx = (ijk[2], ijk[1], ijk[0])
    if n == 0:
        comp = np.zeros_like(m)
    elif lab[click_zyx]:
        comp = lab == lab[click_zyx]
    else:   # nearest component to the click
        dist = ndi.distance_transform_edt(lab == 0, return_indices=True)[1]
        comp = lab == lab[tuple(dist[:, click_zyx[0], click_zyx[1], click_zyx[2]])]

    os.makedirs(a.out, exist_ok=True)
    out_img = sitk.GetImageFromArray(comp.astype(np.uint8))
    out_img.CopyInformation(img)
    sitk.WriteImage(out_img, os.path.join(a.out, f"{a.label}_mask.nii.gz"))

    sp = img.GetSpacing()
    res = {"label": a.label, "point": a.point, "point_space": "voxel" if a.voxel else "RAS mm",
           "found": bool(comp.any())}
    if comp.any():
        long_, short, z = axial_axes_mm(comp, sp)
        zyx = np.argwhere(comp)
        c = zyx.mean(0)
        centre_lps = img.TransformContinuousIndexToPhysicalPoint((c[2], c[1], c[0]))
        res.update({
            "volume_ml": round(float(comp.sum() * np.prod(sp) / 1000), 2),
            "long_axis_mm": round(long_, 1), "short_axis_mm": round(short, 1),
            "measured_on_slice_k": z,
            "centre_ras_mm": [round(-centre_lps[0], 1), round(-centre_lps[1], 1), round(centre_lps[2], 1)],
            "extent_mm": [round(float((zyx[:, i].max() - zyx[:, i].min() + 1) * s), 1)
                          for i, s in ((2, sp[0]), (1, sp[1]), (0, sp[2]))],
        })
    json.dump(res, open(os.path.join(a.out, f"{a.label}.json"), "w"), indent=1)
    print(json.dumps(res))


if __name__ == "__main__":
    main()
