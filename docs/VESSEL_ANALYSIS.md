# Vessel analysis (renal arteries) — TotalSegmentator + vesselFM + 3D Slicer/VMTK

How to look at renal arteries (number, course, accessory arteries, calibre) on an
arterial-phase abdominal CT. **Research use only** — none of these tools is a medical
device, and the output is not a diagnosis.

None of the bundled models segments renal arteries: TotalSegmentator v2 (checked in
v2.16 `map_to_binary.py`) has kidneys, aorta, IVC and kidney cysts but no renal artery
class; VISTA3D and `wholeBody_ct_segmentation` don't have them either. No open
pretrained renal-artery model with downloadable weights was found (Oct 2026). The
workflow therefore combines:

1. **TotalSegmentator** — kidneys and aorta (anatomy, volumes, region of interest).
2. **vesselFM** — a zero-shot 3D vessel segmentation foundation model (CVPR 2025).
3. **3D Slicer + SlicerVMTK** — visual verification, counting arteries, centreline and
   diameter measurement.

## Quick start

All steps below are wrapped in one script (~70 s on the reference GPU):

```bash
./scripts/vessels/run-vessel-analysis.sh --orthanc-series <Orthanc series ID>   # or --image <DICOM dir | NIfTI>
```

Open the result in 3D Slicer with everything pre-loaded — CT in the slice views
(angiography window), bone/bowel-removed CT as a cropped *CT-AAA* volume rendering in an
anterior view, the segmentation and the candidate origins:

```bash
./scripts/vessels/open-vessels-in-slicer.sh                      # newest results/*_vessels_* folder
./scripts/vessels/open-vessels-in-slicer.sh results/<run_dir>    # a specific one
```

It writes to `results/<timestamp>_vessels_<name>/` (git-ignored): `arterial_bone_bowel_removed.nii.gz`
for volume rendering, `renal_segmentation.nii.gz` (1 aorta, 2 left kidney, 3 right kidney,
4 arteries), `renal_artery_candidates.mrk.json` (candidate origins as Slicer markups),
`branch_origins.json`, `summary.json` and `mip_preview.png`. Setup of the two virtual
environments is in the script header; the processing logic is in
`scripts/vessels/vessel_analysis.py`. The sections below explain what each step does.

## What the data allows

| Question | Arterial-phase CT, ~1.25 mm slices | Needs |
|---|---|---|
| Number of renal arteries, accessory arteries, origin level | Usually yes | — |
| Course to the hilum / polar arteries | Usually yes | Kidneys fully in the field of view |
| Degree of stenosis | **Not reliably** — a 3–5 mm artery is only a few voxels wide | Dedicated thin-slice CT angiography, MR angiography or Doppler ultrasound |

Check that the kidneys are fully inside the scan: TotalSegmentator masks that touch the
first/last slice mean a pole is cut off, and a lower-pole accessory artery may be missed.

## 1. Export the series and segment kidneys + aorta

```bash
W=results/renal_case && mkdir -p $W/dicom
# export one series from Orthanc (series ID from http://localhost:8042)
curl -s -u admin:$ORTHANC_PASSWORD http://localhost:8042/series/<SERIES_ID>/archive -o $W/series.zip
# unzip into $W/dicom, then convert:
~/.venvs/totalseg/bin/python -c "import dicom2nifti; dicom2nifti.dicom_series_to_nifti('$W/dicom','$W/arterial.nii.gz',reorient_nifti=True)"

~/.venvs/totalseg/bin/TotalSegmentator -i $W/arterial.nii.gz -o $W/ts \
    --roi_subset kidney_left kidney_right aorta inferior_vena_cava
```

`results/` is git-ignored — patient data never goes into the repository.

Crop a region of interest (kidneys + aorta bounding box, ~15 mm margin, from ~40 mm
below to ~20 mm above the kidneys) and save it as `renal_roi.nii.gz` with the correct
affine. A crop keeps vesselFM fast and reduces false positives.

## 2. vesselFM

One-time setup (PyTorch from the cu128 index for Blackwell GPUs):

```bash
git clone https://github.com/bwittmann/vesselFM ~/tools/vesselFM
uv venv -p 3.11 ~/.venvs/vesselfm
VIRTUAL_ENV=~/.venvs/vesselfm uv pip install torch --index-url https://download.pytorch.org/whl/cu128
grep -v -E '^(torch|pylibtiff|wandb|gpustat)' ~/tools/vesselFM/requirements.txt > /tmp/vfm_req.txt
VIRTUAL_ENV=~/.venvs/vesselfm uv pip install -r /tmp/vfm_req.txt
```

Run (input folder must contain `.nii.gz` files; weights download from Hugging Face
`bwittmann/vesselFM` on first run):

```bash
# clip CT to a vessel-friendly window first, e.g. HU [-100, 500], into $W/vfm_in/
cd ~/tools/vesselFM
PYTHONPATH=$PWD ~/.venvs/vesselfm/bin/python vesselfm/seg/inference.py \
    image_path=$W/vfm_in output_folder=$W/vfm_out ckpt_path=null \
    'tta.scales=[0.5,1,1.5]' post.apply=true
```

Known quirks (vesselFM commit d33b952):

- **Output geometry:** the predicted mask is written in *voxel index order of the
  input, resampled to isotropic spacing* and **without the original affine** (origin 0).
  Resample it back along the resampled axis (e.g. `scipy.ndimage.zoom`) and save it with
  the input's affine before overlaying it on the CT.
- **Bone:** on CT it also marks bone. Remove voxels with HU > ~450 (dilated by 2 voxels)
  and keep only HU > ~150 for enhancing arteries.
- Licences: code GPL-3.0, weights Open RAIL++-M (research / non-commercial).

A simple heuristic then lists vessel branches leaving the aorta (a 1–4 voxel shell
around the TotalSegmentator aorta mask) and whether each connects to a kidney. Branches
running laterally that reach a kidney are **renal artery candidates**; posterior
branches are often lumbar arteries, anterior ones the visceral trunks. Treat the list as
pointers for visual review, not as a count.

## 2b. Remove bone and bowel for a clean 3D view (like vendor "bone removal")

Vendor workstations (e.g. GE Volume Viewer) remove bone automatically before volume
rendering — that is why their 3D views of the renal arteries look clean. The same can be
done with the full TotalSegmentator `total` task (~35 s on the reference GPU):

```bash
~/.venvs/totalseg/bin/TotalSegmentator -i $W/arterial.nii.gz -o $W/ts_total --ml   # one multi-label file
```

Then build a copy of the CT in which these voxels are set to −1000 HU (air):

- **bone:** all `vertebrae_*`, `rib_*`, `sacrum`, `hip_*`, `femur_*`, `sternum`,
  `costal_cartilages`, `scapula_*`, `clavicula_*`, `humerus_*`, `skull` labels, dilated
  by 2 voxels, plus voxels > 700 HU within 4 voxels of bone;
- **bowel** (positive oral contrast is as bright as arteries): `stomach`, `esophagus`,
  `duodenum`, `small_bowel`, `colon`, dilated by 2 voxels;
- **protected — never removed:** `aorta`, `iliac_artery_*`, `kidney_*`, `adrenal_*`,
  `*vena_cava`, the vesselFM arterial mask, all dilated by 1 voxel;
- **left-over fragments:** connected components of > 150 HU that contain a voxel > 450 HU
  and do not touch a protected structure (unsegmented rib heads, calcified nodes).

Save it as e.g. `arterial_bone_bowel_removed.nii.gz` (git-ignored `results/`).

Quick check without Slicer: a full-depth MIP of a noisy CT is dominated by noise maxima
(soft tissue reaches ~150–200 HU), so arteries at ~200 HU barely stand out. Smooth the
volume slightly (Gaussian σ ≈ 1 voxel), limit the MIP to a slab from just in front of the
aorta to behind the kidneys, and window it at about 140–330 HU.

## 3. Verify and measure in 3D Slicer

Install Slicer (`./scripts/install-slicer.sh`), then in the Extensions Manager install
**SlicerVMTK** (optionally also *TotalSegmentator* and *nnInteractive*).

1. **Load data:** `arterial.nii.gz` (or the series from Orthanc via the DICOM module),
   the label map with aorta/kidneys/candidate vessels as a *segmentation*, and the
   candidate origins (`*.mrk.json`, markups in RAS).
2. **Overview:**
   - *Volume Rendering* of `arterial_bone_bowel_removed.nii.gz` with a CT angiography
     preset (e.g. *CT-AAA*). Use the preset's *Shift* slider to move the opacity ramp so
     that contrast-filled arteries (~150–300 HU here) are opaque and kidneys translucent,
     and enable *Crop* (ROI) to the renal region. Rotate to an anterior and a slightly
     cranial view — the result is comparable to a vendor 3D renal-artery view.
   - Thick-slab **MIP** in the slice views (slice view controller → slab reconstruction,
     type *Max*, thickness 10–20 mm), coronal and axial. Renal arteries are easiest to
     follow in a coronal MIP.
3. **Count the arteries:** follow every branch from the aorta to the renal hilum on each
   side. Note the origin level (relative to the SMA / vertebra) and whether it enters the
   hilum or a pole (polar artery).
4. **Segment one artery:** Segment Editor → *Threshold* (≈150–600 HU) restricted to the
   region, then *Islands* (keep selected) or *Grow from seeds*; or click along the vessel
   with nnInteractive.
5. **Centreline:** SlicerVMTK → *Extract Centerline*, input the artery segment, with
   endpoints at the aortic origin and at the hilum. The output table contains the
   maximum inscribed sphere radius along the centreline.
6. **Diameter profile:** SlicerVMTK → *Cross-section Analysis* (and the stenosis
   measurement modules, where your SlicerVMTK version has them) — diameter / area along
   the centreline. Stenosis % ≈ (1 − minimal diameter / reference diameter) × 100.
   On ~1.25 mm data treat any number as indicative only.

Anything that looks abnormal should go to a radiologist, nephrologist or vascular
surgeon with the original study — not be acted on from this pipeline.
