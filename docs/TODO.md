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

- [ ] **ULS+** (Radboud) — click-to-segment any CT lesion with long/short axis
      (RECIST-style measurement). Confirm the weight licence on Zenodo first.
- [ ] **nnInteractive** (DKFZ) — interactive 3D segmentation service next to MONAI
      Label (3D Slicer and OHIF clients, ~10 GB VRAM) for lesion labeling and correction.
- [ ] **LesionLocator** (DKFZ) — lesion tracking across follow-up scans (volumetric
      follow-up, RECIST 1.1 change table).
- [ ] New `scripts/oncology/` analysis (like `scripts/vessels/`): click → mask →
      axes + volume → DICOM SEG/SR in Orthanc → follow-up comparison; include a
      reproducibility test (same lesion, different clicks).
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

- [ ] **TotalSegmentator v2 as the primary segmenter** (CT + MR `total_mr`), not just
      a reference; compare with and likely retire `wholeBody_ct_segmentation` and
      `swin_unetr_btcv`. Verify the `liver_lesions` licence in the installed README.
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
- [ ] Detection output (`lung_nodule_ct_detection`): verify on a scan with a known
      nodule; add small pytest smoke tests on saved responses.

## P5 — Repository and maintenance

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
