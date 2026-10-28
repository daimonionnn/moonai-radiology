# TODO

Open work, highest priority first. Priority is **new models and tools — oncology
first, but not only oncology**. Background, sources and licences for the models:
[research/BETTER_MODELS.md](research/BETTER_MODELS.md) (Slovak original in
[SK/LEPSIE_MODELY_PRE_MOONAI.md](SK/LEPSIE_MODELY_PRE_MOONAI.md)); why the project
exists: [PROJECT_RATIONALE](PROJECT_RATIONALE.md).

All models below are **research only** (no CE mark). Check each weight licence
before use — several are CC BY-NC(-SA), and ULS+, PI-CAI, PanDx and the `brats`
containers state none. **Every new model:** run it silently on 50–200 local
retrospective cases and compare with the radiologists' reports before any study use.

---

## P1 — Oncology models and tools

The core gap: measure any lesion with one click and follow it over time (RECIST).

- [x] **ULS+** (Radboud) — click-to-measure any CT lesion (volume, RECIST long/short
      axis): `scripts/oncology/measure-lesion.sh`, [ONCOLOGY](ONCOLOGY.md). Mean Dice
      0.71 on 9 public lesions. Licence stated inconsistently → non-commercial only.
- [ ] ULS+ next: click from OHIF / a Slicer markup instead of typing coordinates;
      several lesions per study; results as DICOM SEG/SR in Orthanc.
- [x] **nnInteractive** (DKFZ) — server `scripts/oncology/nninteractive-server.sh`, Slicer
      set up by `scripts/oncology/setup-slicer.sh` ([ONCOLOGY](ONCOLOGY.md)). Official
      Docker image fails on Blackwell (PyTorch 2.6) → host venv with cu128.
- [ ] nnInteractive in OHIF (OHIF-AI client) so it also works in the browser.
- [ ] **LesionLocator** (DKFZ) — lesion tracking across follow-up scans (volumetric
      follow-up, RECIST 1.1 change table).
- [ ] Follow-up comparison in `scripts/oncology/` (with LesionLocator): baseline vs
      follow-up per lesion, RECIST 1.1 change table; reproducibility test (same lesion,
      different clicks).
- [ ] **LesionTracer** (autoPET III winner) — whole-body PET/CT lesions (FDG, PSMA).
- [ ] **BrainLesion `brats` package** — replace the old `brats_mri_segmentation`
      bundle (adds brain metastases and meningioma).
- [ ] **PI-CAI** (prostate bpMRI, Siemens/Philips only) and **Sybil** (lung cancer
      risk from low-dose CT).
- [ ] Depending on research projects: **MAMA-MIA** (breast MRI tumours), **PanDx**
      (pancreatic cancer CT), **Mirai** (mammography risk; Hologic-trained).
- [ ] Gaps with no good open model yet — candidates for own research / training:
      automatic whole-body lesion *detection*, bone metastases, lymph nodes,
      head & neck PET/CT, testicular tumours (retroperitoneal nodes).

## P2 — General models and tools (not only oncology)

- [x] **VISTA3D fixed**: image rebuilt with Python 3.11.18 (was 3.11.0rc1 →
      `pytorch-ignite` crashed); tumour candidates via `scripts/oncology/find-tumours-vista3d.sh`
      (liver mets 4/7, no false positives).
- [ ] VISTA3D through MONAI Label / OHIF: add a prompted infer task (the generic bundle
      task sends no `class_vector`).
- [ ] VISTA3D false positives on a normal CT (5 candidates; "colon cancer" 10.8 mL of
      soft-tissue density, ~32 HU). Measure the false-positive rate on more normal scans
      first; candidate filters to evaluate: minimum size for bone lesions, confidence /
      probability output, agreement with a second model (`find-tumours-totalseg.sh` now gives
      the same output format; on the normal CT the two models agreed on none of their
      candidates). Do **not** mask out the bowel —
      that would also remove real colon tumours.

- [ ] **TotalSegmentator v2 as the primary segmenter** (CT + MR `total_mr`), not just
      a reference; compare with and likely retire `wholeBody_ct_segmentation` and
      `swin_unetr_btcv`. (`liver_lesions` runs without a licence — verified.)
- [ ] **NV-Segment-CTMR** (VISTA3D successor, 345+ CT/MR classes) — possible
      replacement for `wholeBrainSeg_UNEST`; check its weight licence.
- [ ] **MRSegmentator** as a second opinion for MR anatomy.
- [ ] Chest X-ray: **TorchXRayVision** (18 findings, CPU-capable).
- [ ] Report VLMs for evaluation only, in a separate "unverified AI suggestion"
      section: **NV-Reason-CT**, **Merlin** (MIT).
- [ ] Evaluate **Kaapana** (DKFZ Heidelberg) — the closest open-source platform;
      decide: build on it, integrate with it, or stay standalone.
- [ ] Commercial marketplaces (deepcOS, CARPL) — how they could sit next to
      Orthanc/OHIF as DICOM nodes where certified products exist.

## P3 — Report quality (LLM)

- [ ] Report only clinically relevant organs and flagged deviations (today it lists
      every structure, incl. ribs and muscles).
- [ ] Stricter IMPRESSION: only flagged findings, no own interpretation (the model
      added an unrequested explanation for a 0.4 cm³ lung lobe).
- [ ] Extend `config/prompts/glossary.json` as Slovak/Czech reports reveal wrong terms.
- [ ] Central-European organ-volume reference cohort (kidney references are
      Japanese, J-MID; liver Korean).

## P4 — Data protection and validation

- [ ] Brain MRI (`wholeBrainSeg_Large_UNEST_segmentation`): affine MNI305 registration
      now added (total 2795 → 1347 cm³). Follow-ups: make the registration
      reproducible (deterministic sampling / single thread); optional N4 bias
      correction; warning for contrast-enhanced T1 (trained on non-contrast); brain
      reference ranges (e.g. hippocampus, ventricles by age/sex). See [EXAMPLES](EXAMPLES.md) §2.
- [ ] Result folder names contain the patient name from DICOM
      (`results/…_<SURNAME>_<NAME>_…`); use a pseudonym / study UID instead —
      required before working with hospital data.
- [ ] Validate one CT and one MRI mask visually in 3D Slicer against a reference tool.
- [ ] Verify `scripts/vessels/run-vessel-analysis.sh` in CPU mode.
- [x] Detection output (`lung_nodule_ct_detection`) verified on LIDC-IDRI-0001: nodule
      found; box format fixed (`cccwhd`). Still: box depth ~2.5× too large (unverified),
      no confidence scores; add pytest smoke tests on saved responses.
- [ ] Extend the public-data tests (more cases per task, brain tumour / BraTS,
      pancreas) — [PUBLIC_DATA_TESTS](research/PUBLIC_DATA_TESTS.md).

## P5 — Repository and maintenance

- [ ] Run `./scripts/check-updates.sh` every few months; re-test on the public cases after
      upgrades. Bundle updates that need a newer MONAI than the image are marked "keep".
- [x] Upgraded 2026-10-28: MONAI 1.4 → **1.6.1**, PyTorch 2.7 → **2.11 (cu128)**, all MONAI
      Zoo bundles to their latest releases, Slicer 5.12.4, TotalSegmentator 2.18, Orthanc
      26.9.1. Needed three fixes: MONAI ≥ 1.5 `Spacingd` vs MONAI Label 0.8.5 (patched in the
      Dockerfile), cuCIM for CUDA 13 pulled by `monai[all]` (replaced with cu12),
      `swin_unetr_btcv` 0.6.0 configs from the zoo dev branch (released 0.5.8 still passes
      `img_size`), `pancreas_ct_dints` `torch.load(weights_only=False)` + CPU fallback. The
      bundle sync in `entrypoint.sh` never updated existing bundles — fixed (version +
      config checksum). Regression on CPU: CT volumes and VISTA3D identical, brain within
      0.1 %, lung nodule box centre moved ~11 mm (still on the nodule, 7 mm from the
      annotation). Previous image kept as `monai-platform/monailabel:monai14`, bundles in
      `models/bundles_monai14/`.
- [x] GPU regression after the upgrade: CT volumes identical (±0.1 cm³), brain 1347.6
      (was 1347.0), VISTA3D and ULS+ identical, `swin_unetr` works.
- [ ] `pancreas_ct_dints_segmentation` (first real test): needs **contrast** CT — on the
      native CT pancreas 15.6 cm³ (wrong), on the arterial phase 116 cm³ (plausible) but a
      **false 5.9 cm³ "pancreatic tumour"** on a normal scan. Do not use the tumour output
      without the PanDx alternative (P1) and a specificity test. The CPU filter that skips
      it may be unnecessary now (map_location falls back to CPU) — verify.
- [ ] OHIF v3.11 → v3.13.13: server side tested (page + Orthanc proxy OK with our config);
      check the viewer in a browser, then switch the tag in both compose files.
- [ ] Make the repository public (Settings → visibility) after a final review.
- [ ] `CONTRIBUTING.md` + issue templates.
- [ ] Multipart `params` parsing is duplicated in `run-inference.sh` and
      `process_findings.py` — merge.
- [ ] Optional: revoke the old NGC key (it is still in the old private repository).

## Later — clinical value

- Own training on hospital data (see [RADIOLOGIST_SUMMARY](RADIOLOGIST_SUMMARY.md)):
  pixel-level expert annotations, hundreds of cases per task, held-out test set;
  start with one narrow task (one organ, one modality).
- Human-in-the-loop review UI — a radiologist accepts/edits every AI finding.
- Provenance & audit: model version, spacing, prompt set and mask with every report.

---

## Done (summary)

Kept short; details are in the git history and the linked docs.

| Area | What was fixed / added |
|---|---|
| Wrong volumes | DICOM→NIfTI on the host instead of MONAI Label `/session/` (liver 226 → 1579 cm³, matches TotalSegmentator within ~1 %); negative slice spacing → `abs()` |
| Invented normals | Reference ranges and flags computed in code, never by the LLM; placeholder ranges replaced with cited sources, sex-specific where available; spleen length (largest connected component — stray fragments gave a false 15.9 cm) |
| Labels / modality | Brain bundle names from `metadata.json`; modality and sex from DICOM passed to the report |
| Detection | Boxes read as world mm + long-axis diameter; explicit "0 findings" |
| LLM report | Remote servers not unloaded; model loaded before the report; `LLM_REASONING_EFFORT`; languages `LLM_REPORT_LANGUAGES` with number check; prompts in `config/prompts/`; cloud LLM via `LLM_API_KEY`; identifying lines removed before any LLM call |
| Vessels | vesselFM + TotalSegmentator renal artery analysis, bone/bowel removal, 3D Slicer loader ([VESSEL_ANALYSIS](VESSEL_ANALYSIS.md)) |
| Platform | `MOONAI_DEVICE=gpu\|cpu\|auto`; host Python venv (`setup-python.sh`); scripts grouped by examination type |
| Security | New repository with fresh history; Orthanc credentials only in `docker/.env` (OHIF proxy adds them server-side); no personal data, IPs or keys tracked; Apache-2.0 licence |

Comparing engines: `./scripts/inference/run-inference.sh` (MONAI Label) and
`./scripts/inference/run-totalseg.sh` (TotalSegmentator) print the same reference
flags via `flag_for()` in `process_findings.py`.
