# Project review, known issues & TODO

Status snapshot of the toolkit, why the current numbers are unreliable, what to
fix before going public, and a prioritized roadmap. Written for someone new to
medical-imaging AI.

---

## 1. Why the segmentation numbers come out "wrong"

Short version: **the models are probably working roughly as designed — the
problems are in how results are labeled, interpreted, and reported.** There are
several separate issues stacked on top of each other.

### 1a. The LLM is *inventing* normal ranges (most dangerous)
The report prompt tells the LLM to *"flag any values outside normal range"* but
the pipeline **never gives it any reference ranges**. So the model makes them up.
In a real report it wrote *"Liver 581 cm³ — normal 1200–1600, significantly LOW"* —
those thresholds were hallucinated. For a clinical-ish tool this is the single
biggest correctness/safety problem: confident, made-up numbers.
- **Fix:** maintain a curated `REFERENCE_RANGES` table (per structure, per model)
  in `process_findings.py`, compute the HIGH/LOW flags *in Python*, and pass the
  LLM only the numbers **plus** the reference value. Instruct it explicitly:
  *"Do not invent reference ranges; only use the ones provided."* The git history
  shows a `REFERENCE_RANGES` table existed and regressed — it should be restored
  and wired into both the volume table and the LLM prompt.

### 1b. Brain model shows `structure_15` instead of anatomy names
The `wholeBrainSeg_Large_UNEST_segmentation` report lists `structure_1 … _132`
with no names, so the LLM has zero anatomical context and produces a meaningless
"all 132 structures within normal limits" report. Label-name resolution failed
for this bundle: the inference response had no `label_names`, and the `/info/`
fallback didn't return a usable map either.
- **Fix:** read the label map from the **bundle's own `configs/metadata.json`**
  (`network_data_format.outputs.pred.channel_def`) as a third fallback — the
  brain bundle ships names there. Verify the `{int → name}` inversion for each
  model against a known series.

### 1c. Volumes were genuinely low / physically implausible  *(ROOT CAUSE FOUND + FIXED)*
Liver came out 226 cm³ on a full native CT (adult liver ~1200–1800). **Root
cause:** uploading the DICOM series via MONAI Label's `/session/?uncompress=true`
endpoint lets the server do the DICOM→NIfTI conversion, and that converted
geometry breaks the bundle's resample-back step (`Invertd` shows `Invert: 0.0000`
in the latencies = no-op). The returned mask carries the fine spacing but a voxel
count stuck at the model's coarse 1.5 mm grid, so volumes are undercounted by
~the resolution ratio. The organ is found in the right place — just under-filled.

**Fix (done):** convert DICOM→NIfTI on the host with `dicom2nifti` (`reorient=True`)
and upload the `.nii.gz` directly (`file=@`) instead of using `/session/`.
`run-inference.sh` now does this automatically. Result on the same series:

| organ | /session/ (broken) | NIfTI (fixed) | TotalSegmentator | ref |
|---|---|---|---|---|
| liver | 226 | **1579** | 1595 | 1200–1800 |
| kidney_left | 19 | 185 | 181 | 100–220 |
| kidney_right | 5 | 180 | 178 | 100–220 |
| pancreas | 23 | 92 | 132 | 40–120 |

The fixed MONAI output and TotalSegmentator agree within ~1 % on the liver —
independent confirmation that the fix is correct.

### 1d. Negative slice spacing → false "resampling" warning  *(FIXED)*
`get_original_metadata()` read `SpacingBetweenSlices` verbatim; some scanners
store it signed (e.g. `-1.25 mm`), which made "Original 0.80×0.80×**-1.25**"
differ from the mask's `+1.25` and fired a bogus mismatch warning (and would give
a negative voxel volume if that spacing were ever used for volume). Now wrapped in
`abs()`. The same pattern exists in `test_script.py` (throwaway) — ignore or delete.

### 1e. Detection model output parsing  *(FIXED)*
Inspecting the real response, `lung_nodule_ct_detection` returns
`box` / `label` / `centroids` (with `AffineBoxToWorldCoordinated` in post, so
boxes are in **world millimetres**, not voxels — the old code mislabelled them
"vox"). On the test scan the model legitimately found **0 nodules** (empty `box`),
which previously rendered as silence. `format_detection()` now: reads boxes as mm
with a long-axis diameter and confidence, and emits an explicit "0 findings" line
for a negative scan. Not yet verified on a known-positive case (no such series
available) — worth confirming against a scan with a documented nodule.

### 1f. Modality confusion in reports
Brain **MRI** reports say *"via CT scan"* / *"Whole-body CT"*. The prompt doesn't
tell the LLM the true modality, so it guesses. Pass modality explicitly from the
DICOM `Modality` tag into the prompt.

> **Bottom line for you:** your instinct ("maybe resolution/settings differ from
> training") is partly right (1c), but the *reported* wrongness is dominated by
> the software issues 1a/1b/1f — the tool is describing correct-ish masks with
> invented, mislabeled, wrong-modality text. Fix labeling + reference ranges +
> modality first; then validate the actual masks visually.

---

## 2. Correctness bugs (code)

| # | File | Issue | Status |
|---|------|-------|--------|
| 2.1 | process_findings.py | LLM invents reference ranges — added `REFERENCE_RANGES`, flags computed in Python, prompt forbids inventing | ✅ done |
| 2.1b | process_findings.py | Placeholder ranges replaced with cited sources (Prassopoulos 1997 spleen, Stefanovic 2012 pancreas, Kim 2021 liver, J-MID 2026 kidneys p10–p90), sex-specific where available (DICOM PatientSex), spleen craniocaudal length check, caveat for pancreas (engines disagree ~40 %). Still to do: a Central-European TotalSegmentator reference cohort | ✅ done |
| 2.2 | process_findings.py | Brain-model labels unresolved — added `metadata.json` fallback (133 classes resolve) | ✅ done |
| 2.3 | process_findings.py | Detection output parsing — boxes now read as WORLD mm coords + long-axis diameter + confidence; empty result reports an explicit "0 findings" line instead of silence | ✅ done |
| 2.4 | process_findings.py / run-inference.sh | Modality now read from DICOM tag + passed to LLM; prompt uses it | ✅ done |
| 2.5 | process_findings.py | Negative spacing → false warning — fixed (`abs()`) | ✅ done |
| 2.6 | process_findings.py / run-inference.sh | DICOM `/session/` path broke resample-back → tiny volumes; now convert DICOM→NIfTI on host and upload NIfTI | ✅ done |
| 2.7 | LLM report | Thinking models used the whole token budget on reasoning → empty report; remote LLM was unloaded by run-inference.sh. Fixed: `LLM_REASONING_EFFORT=none`, remote servers are not unloaded, model is loaded before the report, empty response gives a clear warning | ✅ done |
| 2.8 | Multipart parsing | `params`-extraction regex duplicated in `run-inference.sh` and `process_findings.py` | 🟡 low |

### Segmentation engines (both available, for comparison)
- **MONAI Label** — `./scripts/inference/run-inference.sh --model wholeBody_ct_segmentation --image <dir|nifti>`
- **TotalSegmentator** — `./scripts/inference/run-totalseg.sh --image <dir|nifti>` (de-facto standard, good ground-truth). Both print the **same** reference-range flags via the shared `flag_for()` in `process_findings.py`, so results are directly comparable.

### Host Python dependencies (required by the scripts)
`process_findings.py` / `run-inference.sh` need `pydicom nibabel numpy dicom2nifti`
on the `python3` that runs them. TotalSegmentator lives in its own venv
(`~/.venvs/totalseg`, torch+torchvision from the **cu128** index for Blackwell).
Add a `requirements.txt`; the report LLM step needs nothing extra (stdlib urllib).

---

## 3. Security & GitHub-prep

The project is published from a **new repository with a fresh history**
(`moonai-radiology`). The old private repository's history contains a real NGC
API key, the old default Orthanc password and — in its first commit — a full
patient CT series (DICOM). That history must never be made public.

### 3.1 Secrets  *(DONE in the working tree)*
- Orthanc credentials live only in `docker/.env` (git-ignored). Compose passes
  them to Orthanc as `ORTHANC__REGISTERED_USERS`; the healthcheck reads them
  from the environment; OHIF's nginx proxy adds them server-side
  (`docker/ohif/entrypoint.sh`), so `app-config.js` no longer contains any.
- `docker/.env.example` ships `ORTHANC_PASSWORD=change_me`; `start.sh` refuses
  to start until it is changed.
- NGC key: not in the new repository. Optional: revoke the old key at
  ngc.nvidia.com, since the old private history still contains it.

### 3.2 Junk files  *(DONE)*
`datasets/.lock`, the stray control-character file and the ad-hoc
`test_script*.py` are no longer tracked.

### 3.3 `docs/new 1.txt`  *(DONE)*
Removed; the original brief and plan are kept as
[history/INITIAL_PLAN.md](history/INITIAL_PLAN.md).

### 3.4 Personal data and paths  *(DONE)*
Private LAN addresses replaced by `localhost` defaults (real address only in
`docker/.env`), patient-named dataset paths replaced by `datasets/ct/<series>`,
no absolute home paths.

### 3.5 Before publishing checklist
- [x] Orthanc credentials only in `docker/.env`
- [x] Fresh repository history (no DICOM, no keys)
- [x] Junk files untracked
- [x] Remove/relocate `docs/new 1.txt`
- [x] Fix absolute paths and personal data in docs
- [x] Add a `LICENSE` (Apache-2.0)
- [ ] Add `CONTRIBUTING.md` + issue templates
- [x] Confirm `git ls-files` contains **no** patient data, `.env`, models, or results
- [x] Keep the "not a medical device" disclaimer prominent
- [ ] Optional: revoke the old NGC key (still in the old private history)

---

## 4. Documentation & polish

- Root `README.md` created (GitHub landing page) — keep `docs/README.md` as the detailed index.
- ~~`docs/README.md` still lists `RAM 64 GB` / RTX 5090 as *the* spec — reword to
  "reference hardware" and add the CPU option.~~ ✅ (now RTX PRO 6000 96 GB as
  reference, RTX 5090 32 GB + separate LLM machine as the smaller option)
- ~~Add a real repository name / description~~ ✅ MOONAI Radiology.
- Consider a `requirements.txt` for the host-side Python scripts
  (`nibabel`, `numpy`, `pydicom`, `httpx`).

---

## 5. Prioritized roadmap

**Now (make current features trustworthy)**
1. ~~Restore `REFERENCE_RANGES` + compute flags in Python (2.1).~~ ✅
2. ~~Fix brain-model label resolution via `metadata.json` (2.2).~~ ✅
3. ~~Pass true modality to the LLM; stop it inventing facts (2.4, 2.6 prompt).~~ ✅
4. Validate one CT and one MRI mask visually in 3D Slicer vs. a reference tool (1c).

**Next (make it shareable)**
5. ~~Security/GitHub-prep §3.~~ ✅ (fresh repository, credentials only in `docker/.env`)
6. ~~CPU path~~ ✅ `MOONAI_DEVICE=gpu|cpu|auto`; verified for MONAI Label inference.
   Still to verify on CPU: `scripts/vessels/run-vessel-analysis.sh`.
7. Detection output parsing (2.3); add small pytest smoke tests on saved responses.
8. Make the repository public (Settings → visibility) once reviewed; add
   `CONTRIBUTING.md` + issue templates.

**Report quality (LLM)**
- [x] Report languages `LLM_REPORT_LANGUAGES` (e.g. `en,sk`), number check on translations.
- [x] Editable prompts in `config/prompts/` (`LLM_PROMPT_DIR`).
- [x] Optional cloud LLM (`LLM_API_KEY`); identifying lines removed before any LLM call.
- [ ] Report only clinically relevant organs and flagged deviations (today it lists
      every structure, incl. ribs and muscles).
- [ ] Stricter IMPRESSION: only flagged findings, no own interpretation (the model
      added an unrequested explanation for a 0.4 cm³ lung lobe).
- [ ] Extend `glossary.json` as Slovak/Czech reports reveal wrong terms.
- [ ] Central-European organ-volume reference cohort (current kidney references are
      Japanese, J-MID).

**Data protection**
- [ ] Result folder names contain the patient name from DICOM
      (`results/…_<SURNAME>_<NAME>_…`); use a pseudonym / study UID instead — required before
      working with hospital data.

**Later (the actual clinical value)**
9. Tumor/anomaly detection. Your 80/20 (positive/healthy) intuition is in the
   right spirit but be careful: for *detection/segmentation* you need
   **pixel-level expert annotations**, not just image-level labels, and hundreds
   of cases per body region/modality with a held-out test set. Start with one
   narrow, well-scoped task (e.g. one organ, one modality) rather than "all tumors".
10. Human-in-the-loop review UI so a radiologist accepts/edits every AI finding.
11. Provenance & audit: store model version, spacing, and mask with every report.

**Evaluate more tools and models (focus: oncology)** — see
[PROJECT_RATIONALE](PROJECT_RATIONALE.md) for why, and the research report
[research/BETTER_MODELS.md](research/BETTER_MODELS.md) (Slovak original in
[SK/LEPSIE_MODELY_PRE_MOONAI.md](SK/LEPSIE_MODELY_PRE_MOONAI.md)) for sources and licences.
All of these are research-only (no CE mark); check each weight licence before use —
several are CC BY-NC(-SA), and ULS+, PI-CAI, PanDx and the `brats` containers have
no stated weight licence.
- [ ] **TotalSegmentator v2** — integrate and test as the *primary* CT/MR organ
      segmenter (not just a reference); compare against and likely retire
      `wholeBody_ct_segmentation` and `swin_unetr_btcv`; add the MR (`total_mr`)
      task. Verify the `liver_lesions` licence in the installed version's README
      (sources disagree).
- [x] **vesselFM** (zero-shot 3D vessel segmentation) — integrated for renal
      arteries: `scripts/vessels/`, [VESSEL_ANALYSIS](VESSEL_ANALYSIS.md).
- [ ] **ULS+** (Radboud) — click-to-segment any CT lesion with long/short axis
      (RECIST-style measurement).
- [ ] **nnInteractive** — interactive 3D segmentation service next to MONAI Label
      (has 3D Slicer and OHIF clients, ~10 GB VRAM) for fast lesion labeling.
- [ ] **LesionLocator** (DKFZ) — lesion tracking across follow-up scans.
- [ ] **LesionTracer** (autoPET III winner) — whole-body PET/CT lesion segmentation.
- [ ] **BrainLesion `brats` package** — replace the old `brats_mri_segmentation`
      bundle (adds brain metastases and meningioma).
- [ ] **PI-CAI** (prostate bpMRI, Siemens/Philips only) and **Sybil** (lung cancer
      risk from low-dose CT).
- [ ] Depending on research projects: **MAMA-MIA** (breast MRI tumors), **PanDx**
      (pancreatic cancer CT), **Mirai** (mammography risk; Hologic-trained).
- [ ] Each new model: run silently on 50–200 local retrospective cases and compare
      with the radiologists' reports before any study use.
- [ ] Known gaps with no good open model yet: automatic whole-body lesion
      *detection*, bone metastases, lymph nodes, head & neck PET/CT.

**Evaluate other platforms**
- [ ] **Kaapana** (DKFZ Heidelberg) — open-source research AI platform for
      hospitals; the closest open alternative. Install it, compare features and
      decide whether to build on it, integrate with it, or continue standalone.
- [ ] Commercial AI marketplaces (deepcOS, CARPL) — understand how they could coexist
      with Orthanc/OHIF as DICOM nodes, for areas where certified products exist.
