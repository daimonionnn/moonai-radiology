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
      `pytorch-ignite` crashed); tumour candidates via `scripts/oncology/find-tumours.sh`
      (liver mets 4/7, no false positives).
- [ ] VISTA3D through MONAI Label / OHIF: add a prompted infer task (the generic bundle
      task sends no `class_vector`).

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

- [ ] Version upgrades (checked 2026-10-28): **OHIF v3.11 → v3.13.13** (test the
      app-config / proxy), **MONAI 1.4 → 1.6** only when MONAI Label supports it (0.8.5
      is the latest and is built on 1.4), PyTorch in the image (2.7) with MONAI.
      Done: Slicer 5.12.4, TotalSegmentator 2.18, Orthanc 26.9.1 image, image Python fix.

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
