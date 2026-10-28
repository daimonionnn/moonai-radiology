#!/usr/bin/env python3
"""
Renal vessel analysis helpers — called by run-vessel-analysis.sh.

  prepare      <run_dir>   kidney/aorta ROI crop + vesselFM input (HU-clipped)
  postprocess  <run_dir>   map vesselFM output back, filter bone, list branch
                           origins, write Slicer files, bone/bowel-removed CT, MIP

Expects in <run_dir>: arterial.nii.gz, ts_total.nii (TotalSegmentator --ml),
and (for postprocess) vfm_out/renal_roi_pred.nii.gz.

Research use only — not a medical device. See docs/VESSEL_ANALYSIS.md.
"""
import json
import sys
from pathlib import Path

import nibabel as nib
import numpy as np
from nibabel.processing import resample_from_to
from scipy import ndimage as ndi
from totalsegmentator.map_to_binary import class_map

CLASSES = class_map["total"]
BONE = ("vertebrae", "rib_", "sacrum", "hip_", "femur", "sternum", "costal_cartilages",
        "scapula", "clavicula", "humerus", "skull")
BOWEL = ("small_bowel", "colon", "duodenum", "stomach", "esophagus")
PROTECT = ("aorta", "iliac_artery", "kidney", "adrenal", "vena_cava")

VFM_CLIP_HU = (-100, 500)   # vesselFM input window
ARTERY_MIN_HU = 150         # enhancing arteries in arterial phase
BONE_HU = 450               # anything denser is treated as bone


def ids(keywords):
    return [k for k, v in CLASSES.items() if any(w in v for w in keywords)]


def label_mask(lab, name):
    inv = {v: k for k, v in CLASSES.items()}
    return lab == inv[name]


def load(run):
    img = nib.load(run / "arterial.nii.gz")
    lab = np.asarray(nib.load(run / "ts_total.nii").dataobj).astype(np.int16)
    if lab.shape != img.shape:
        sys.exit("TotalSegmentator output does not match the CT grid")
    return img, lab


def prepare(run):
    img, lab = load(run)
    ct = img.get_fdata()
    sp = np.array(img.header.get_zooms()[:3])
    vz = np.prod(sp) / 1000

    summary = {}
    for name in ("kidney_left", "kidney_right", "aorta", "inferior_vena_cava"):
        m = label_mask(lab, name)
        if not m.any():
            summary[name] = None
            continue
        z = np.argwhere(m)[:, 2]
        summary[name] = dict(
            volume_cm3=round(float(m.sum() * vz), 1),
            mean_hu=round(float(ct[m].mean())),
            touches_scan_edge=bool(z.min() == 0 or z.max() == ct.shape[2] - 1),
        )
    if not (summary["kidney_left"] or summary["kidney_right"]) or not summary["aorta"]:
        sys.exit("Kidneys or aorta not found — is this an abdominal CT?")

    # ROI: kidneys + aorta, 15 mm in-plane margin, 40 mm below / 20 mm above the kidneys
    kid = label_mask(lab, "kidney_left") | label_mask(lab, "kidney_right")
    box = np.argwhere(kid | label_mask(lab, "aorta"))
    kz = np.argwhere(kid)[:, 2]
    m = int(15 / sp[0])
    lo = [max(0, box[:, 0].min() - m), max(0, box[:, 1].min() - m), max(0, kz.min() - int(40 / sp[2]))]
    hi = [min(ct.shape[0], box[:, 0].max() + m + 1), min(ct.shape[1], box[:, 1].max() + m + 1),
          min(ct.shape[2], kz.max() + int(20 / sp[2]) + 1)]
    crop = tuple(slice(a, b) for a, b in zip(lo, hi))
    aff = img.affine.copy()
    aff[:3, 3] = img.affine[:3, :3] @ np.array(lo) + img.affine[:3, 3]
    roi = ct[crop]
    nib.save(nib.Nifti1Image(roi.astype(np.int16), aff), run / "renal_roi.nii.gz")
    (run / "vfm_in").mkdir(exist_ok=True)
    nib.save(nib.Nifti1Image(np.clip(roi, *VFM_CLIP_HU).astype(np.float32), aff),
             run / "vfm_in" / "renal_roi.nii.gz")

    json.dump(dict(structures=summary, roi_lo=[int(v) for v in lo], roi_hi=[int(v) for v in hi]),
              open(run / "summary.json", "w"), indent=1)
    for k, v in summary.items():
        print(f"  {k:20s} {v}")
    for k in ("kidney_left", "kidney_right"):
        if summary[k] and summary[k]["touches_scan_edge"]:
            print(f"  WARNING: {k} touches the first/last slice — a pole may be cut off; "
                  "its volume and a polar accessory artery may be missed")
    print(f"  ROI {roi.shape}")


def vessels_on_roi(run, roi):
    """vesselFM writes its mask in input index order, resampled to isotropic spacing,
    without the input affine — resample back to the ROI grid and restore the affine."""
    pred = nib.load(run / "vfm_out" / "renal_roi_pred.nii.gz").get_fdata().astype(np.float32)
    factors = [r / p for r, p in zip(roi.shape, pred.shape)]
    return ndi.zoom(pred, factors, order=1) > 0.5


def postprocess(run):
    img, lab = load(run)
    roi_img = nib.load(run / "renal_roi.nii.gz")
    R = roi_img.get_fdata()
    sp = np.array(roi_img.header.get_zooms()[:3])

    V = vessels_on_roi(run, R)
    if not V.any() or np.median(R[V]) < ARTERY_MIN_HU:
        print("  WARNING: vesselFM mask is empty or not on bright voxels — check orientation")
    bone = ndi.binary_dilation(R > BONE_HU, iterations=2)
    art = V & ~bone & (R > ARTERY_MIN_HU)
    nib.save(nib.Nifti1Image(art.astype(np.uint8), roi_img.affine), run / "vessels_arterial_roi.nii.gz")

    def on_roi(name):
        m = nib.Nifti1Image(label_mask(lab, name).astype(np.uint8), img.affine)
        return resample_from_to(m, roi_img, order=0).get_fdata() > 0

    aorta = on_roi("aorta")
    kidneys = {s: on_roi(f"kidney_{s}") for s in ("left", "right")}

    # Branch origins: arterial voxels in a 1–4 voxel shell around the aorta
    shell = ndi.binary_dilation(aorta, iterations=4) & ~ndi.binary_dilation(aorta, iterations=1)
    olab, n = ndi.label(art & shell, structure=np.ones((3, 3, 3)))
    clab, _ = ndi.label(art & ~aorta, structure=np.ones((3, 3, 3)))
    kcen = {s: np.argwhere(k).mean(0) for s, k in kidneys.items() if k.any()}
    kdil = {s: ndi.binary_dilation(k, iterations=3) for s, k in kidneys.items()}

    origins, points = [], []
    for i in range(1, n + 1):
        vox = np.argwhere(olab == i)
        if len(vox) < 3:
            continue
        cen = vox.mean(0)
        z = int(round(cen[2]))
        a = np.argwhere(aorta[:, :, max(0, z - 1):z + 2])
        if not len(a):
            continue
        d = (cen[:2] - a.mean(0)[:2]) * sp[:2]
        comps = set(np.unique(clab[olab == i])) - {0}
        reaches = [s for s in kcen if any(((clab == c) & kdil[s]).any() for c in comps)]
        lateral = abs(d[0]) > abs(d[1])
        o = dict(id=i, z_mm=round(float(cen[2] * sp[2]), 1), lateral_mm=round(float(d[0]), 1),
                 ap_mm=round(float(d[1]), 1), voxels=len(vox), reaches_kidney=reaches,
                 renal_candidate=bool(reaches and lateral))
        origins.append(o)
        if o["renal_candidate"]:
            world = (roi_img.affine @ np.r_[cen, 1])[:3]
            points.append({"label": f"{'/'.join(reaches)} renal candidate z{o['z_mm']:.0f}mm",
                           "position": [round(float(v), 2) for v in world]})
    origins.sort(key=lambda o: -o["z_mm"])

    json.dump(origins, open(run / "branch_origins.json", "w"), indent=1)
    json.dump({"@schema": "https://raw.githubusercontent.com/slicer/slicer/master/Modules/Loadable/"
                          "Markups/Resources/Schema/markups-schema-v1.0.3.json#",
               "markups": [{"type": "Fiducial", "coordinateSystem": "RAS", "coordinateUnits": "mm",
                            "controlPoints": points}]},
              open(run / "renal_artery_candidates.mrk.json", "w"), indent=1)

    seg = np.zeros(R.shape, np.uint8)
    seg[art] = 4
    seg[aorta] = 1
    seg[kidneys["left"]] = 2
    seg[kidneys["right"]] = 3
    nib.save(nib.Nifti1Image(seg, roi_img.affine), run / "renal_segmentation.nii.gz")

    removed = remove_bone_bowel(run, img, lab, art, roi_img)
    mip_preview(run, removed, img, lab)

    print(f"  branch origins: {len(origins)}, renal artery candidates: {len(points)}")
    for o in origins:
        if o["renal_candidate"]:
            print(f"    -> {'/'.join(o['reaches_kidney'])}: z={o['z_mm']} mm, lateral {o['lateral_mm']} mm")


def remove_bone_bowel(run, img, lab, art_roi, roi_img):
    ct = np.asarray(img.dataobj).astype(np.int32)
    bone = np.isin(lab, ids(BONE))
    protect = np.isin(lab, ids(PROTECT))
    protect |= resample_from_to(nib.Nifti1Image(art_roi.astype(np.uint8), roi_img.affine),
                                img, order=0).get_fdata() > 0
    protect = ndi.binary_dilation(protect, iterations=1)

    rem = ndi.binary_dilation(bone, iterations=2) | ndi.binary_dilation(np.isin(lab, ids(BOWEL)), iterations=2)
    rem |= (ct > 700) & ndi.binary_dilation(bone, iterations=4)
    rem &= ~protect
    ct[rem] = -1000

    # Left-over dense fragments (rib heads, calcified nodes) not touching protected anatomy
    L, n = ndi.label(ct > ARTERY_MIN_HU)
    idx = np.arange(1, n + 1)
    mx = np.asarray(ndi.maximum(ct.astype(np.float64), L, idx))
    touch = np.asarray(ndi.maximum(protect.astype(np.float64), L, idx))
    frag = ndi.binary_dilation(np.isin(L, idx[(mx > BONE_HU) & (touch == 0)]), iterations=1) & ~protect
    ct[frag] = -1000

    nib.save(nib.Nifti1Image(ct.astype(np.int16), img.affine), run / "arterial_bone_bowel_removed.nii.gz")
    return ct


def mip_preview(run, ct, img, lab):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    sp = img.header.get_zooms()
    s = ndi.gaussian_filter(ct.astype(np.float32), (1, 1, 0.7))
    kid = label_mask(lab, "kidney_left") | label_mask(lab, "kidney_right")
    y = np.argwhere(kid | label_mask(lab, "aorta"))[:, 1]
    y0, y1 = max(0, y.min() - 40), min(ct.shape[1], y.max() + 10)
    mip = np.clip(s[:, y0:y1, :].max(1), 140, 330).T[::-1]
    plt.figure(figsize=(8, 6))
    plt.imshow(mip, cmap="gray", aspect=sp[2] / sp[0])
    plt.axis("off")
    plt.title("Coronal slab MIP, bone + bowel removed")
    plt.tight_layout()
    plt.savefig(run / "mip_preview.png", dpi=90)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("prepare", "postprocess"):
        sys.exit(__doc__)
    {"prepare": prepare, "postprocess": postprocess}[sys.argv[1]](Path(sys.argv[2]))
