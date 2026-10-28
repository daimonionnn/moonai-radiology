# Tests on public tumour cases

The models were first only run on studies without findings. To see how they behave on
real tumours, they were run on three public CT cases with expert annotations
(2026-10-28, reference GPU). One case per task — a smoke test, not a validation.

| Case | Source / licence | Finding | Expert annotation |
|---|---|---|---|
| LIDC-IDRI-0001 | [TCIA LIDC-IDRI](https://www.cancerimagingarchive.net/collection/lidc-idri/), CC BY 3.0 | lung nodule (7.3 cm³), 2.5 mm slices | DICOM SEG (reader 1) |
| CRLM-CT-1105 | [TCIA Colorectal-Liver-Metastases](https://www.cancerimagingarchive.net/collection/colorectal-liver-metastases/), CC BY 4.0 | 7 liver metastases (0.1–4.4 cm³, 10.1 cm³ total), 5 mm slices | DICOM SEG |
| KiTS23 case_00000 | [KiTS23](https://github.com/neheller/kits23), CC BY-NC-SA 4.0 | kidney tumour (8.7 cm³) | NIfTI |

Downloaded to `datasets/ct/public/` (git-ignored). Dice = voxel overlap with the expert
mask; *found* = expert lesions touched by the prediction; *false-pos comps* = predicted
connected components not touching any expert lesion.

## Results

| Task | Model | Result |
|---|---|---|
| Lung nodule | `lung_nodule_ct_detection` (MONAI) | **Found**: box centre ~8 mm from the annotated nodule, axial long axis 19.7 mm (annotation ≈ 24 mm equivalent sphere). Plus 7 small candidates of 3–5 mm (not in this reader's annotation). |
| Lung nodule | TotalSegmentator `lung_nodules` | **Found 1/1, Dice 0.82**, 5.6 vs 7.3 cm³, no false positives. |
| Liver metastases | TotalSegmentator `liver_lesions` | **Found 4/7, Dice 0.57**, 8.0 vs 10.1 cm³, 3 false-positive components. Missed lesions are the smallest (≤ 0.5 cm³) on 5 mm slices. |
| Kidney tumour | TotalSegmentator `kidney_cysts` | Dice 0.09 — expected: the task segments **cysts**, not solid tumours. No *automatic* model covers kidney tumours (ULS+ measures them on a click — below). |
| Lung nodule | VISTA3D `lung tumor` (prompted, after the image fix) | **Found 1/1, Dice 0.82**, 8.4 vs 7.3 cm³, 1 false-positive component. |
| Liver metastases | VISTA3D `hepatic tumor` (prompted) | **Found 4/7, Dice 0.64**, 9.1 vs 10.1 cm³, **no false positives**. (No kidney-tumour class.) |
| All 9 lesions (click = point nearest each lesion's centre) | **ULS+** (`scripts/oncology/measure-lesion.sh`) | **9/9 measured, mean Dice 0.71**: lung nodule 0.88 (7.8 vs 7.3 mL), kidney tumour 0.88 (7.4 vs 8.7 mL), liver metastases 0.35–0.82 (lowest for the 0.08 mL lesion on 5 mm slices). |

## Issues found and fixed

- **Detection boxes were misread.** `lung_nodule_ct_detection` returns boxes as
  `cccwhd` (centre + size, its last `ConvertBoxModed` step), not two corners, so the
  report showed "nodules" of 100–340 mm. Fixed in `process_findings.py`; the axial long
  axis is reported (RECIST). The box depth came out ~2.5× the annotated extent (= the
  slice thickness) and is marked unverified. No confidence score is returned by MONAI
  Label (`label_scores` are dropped).
- **TotalSegmentator `liver_lesions` needs no licence** — it ran without one (resolves the
  conflicting claim in [BETTER_MODELS](BETTER_MODELS.md)).

## Issues found, still open

- ~~VISTA3D did not work~~ **fixed**: the image used Ubuntu 22.04's `python3.11`
  3.11.0rc1 (pre-release, `enum` bug → `pytorch-ignite` crashed). Rebuilt with Python
  3.11.18 from the deadsnakes PPA; VISTA3D now runs via `scripts/oncology/find-tumours.sh`.
  Still open: MONAI Label's generic bundle task sends VISTA3D no prompt (`class_vector`),
  so it fails when called through the MONAI Label API / OHIF.
- **Kidney tumours** have no automatic detector (KiTS23 winner weights are not public); ULS+ measures them when clicked.

All of this is tracked in [TODO](../TODO.md).
